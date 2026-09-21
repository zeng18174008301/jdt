import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import BlueStoneIM

@MainActor
final class DomainStoreTests: XCTestCase {
    func testContactProfileReconciliationPublishesOneCompleteBatchAndNoNoop() {
        let store = ConversationStore()
        var original = (0..<400).map { makeConversation(id: "peer-\($0)", unread: 3, lastMsgSeq: 9, lastReadSeq: 6) }
        original[0].isPinned = true
        let group = makeConversation(id: "group", kind: .group, unread: 7, lastMsgSeq: 10, lastReadSeq: 3)
        store.conversations = original + [group]
        var published: [[Conversation]] = []
        let observation = store.$conversations.dropFirst().sink { published.append($0) }
        defer { observation.cancel() }
        func refresh() -> Int {
            store.refreshDirectConversationProfiles(
                channelIDForConversation: { $0.id },
                titleForChannel: { "new-" + $0 },
                participantsForChannel: { [self.makeUser(id: $0, name: "new-" + $0,
                    avatarURL: "https://example.invalid/avatar", avatarVersion: "2", avatarUpdatedAt: "now")] }
            )
        }
        XCTAssertEqual(refresh(), 400)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first, store.conversations)
        XCTAssertTrue(store.conversations[0].isPinned)
        XCTAssertEqual(store.conversations[0].unread, 3)
        XCTAssertEqual(store.conversations[0].lastReadSeq, 6)
        XCTAssertEqual(store.conversations.last, group)
        XCTAssertTrue(store.conversations.prefix(400).allSatisfy {
            $0.title == "new-" + $0.id && $0.avatarVersion == "2" && $0.participants.count == 1
        })
        XCTAssertEqual(refresh(), 0)
        XCTAssertEqual(published.count, 1)
        // Other mutations remain immediately observable, including an ABA toggle.
        store.conversations[0].isPinned = false
        store.conversations[0].isPinned = true
        XCTAssertEqual(published.count, 3)
    }

    func testConversationUserLookupPreservesAliasPriorityAndRebuildsForNewScope() {
        let me = makeUser(id: "self")
        let first = makeUser(id: "canonical-first", userID: " legacy ", username: " duplicate ")
        let second = makeUser(id: "canonical-second", username: "duplicate")
        let member = makeUser(id: "group-member", userID: "legacy", username: "member-alias")
        let lookup = ConversationUserLookup(currentUser: me, currentIdentifiers: ["self", "account"],
            contacts: [first, second, makeUser(id: "account")], groupMembers: [member])
        XCTAssertEqual(lookup.user(for: " account "), me)
        XCTAssertEqual(lookup.user(for: "legacy"), first)
        XCTAssertEqual(lookup.user(for: " duplicate "), first)
        XCTAssertEqual(lookup.user(for: "member-alias"), member)
        XCTAssertNil(lookup.user(for: " "))
        XCTAssertNil(lookup.user(for: "missing"))
        let next = ConversationUserLookup(currentUser: second, currentIdentifiers: [second.id],
            contacts: [], groupMembers: [])
        XCTAssertNil(next.user(for: "legacy"))
        XCTAssertEqual(next.user(for: second.id), second)
    }

    func testGroupNameProjectionUpdatesAuthorWithoutRewritingSnapshotOrGlobalIdentity() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let current = makeUser(id: "self", name: "我")
        let global = makeUser(id: "peer", name: "个人昵称")
        state.currentUser = current
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

        XCTAssertEqual(ConversationUnreadBadgeProjection.total([active, other, muted]), 23)
        XCTAssertEqual(
            ConversationUnreadBadgeProjection.total(
                [active, other, muted],
                excludingConversationID: active.id
            ),
            16
        )

        active.unread = 0
        active.lastReadSeq = 98
        XCTAssertEqual(ConversationUnreadBadgeProjection.total([active, other, muted]), 16)
        XCTAssertEqual(
            ConversationUnreadBadgeProjection.total(
                [active, other, muted],
                excludingConversationID: active.id
            ),
            16
        )
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

    func testGroupMemberCountVisibilityStoreScopesRecords() throws {
        let suiteName = "GroupMemberCountVisibilityStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let record = GroupMemberCountVisibilityRecord(
            showGroupMemberCount: false,
            generation: 3,
            contractVersion: 1
        )

        GroupMemberCountVisibilityStore.save(record, scope: "tenant-a|user-a|app-1", defaults: defaults)

        XCTAssertEqual(
            GroupMemberCountVisibilityStore.load(scope: "tenant-a|user-a|app-1", defaults: defaults),
            record
        )
        XCTAssertNil(
            GroupMemberCountVisibilityStore.load(scope: "tenant-a|user-b|app-1", defaults: defaults)
        )
    }

    func testConversationScrubbingRemovesGroupTotalsButRetainsMemberAndReceiptRows() {
        let memberOne = IMUser(
            id: "u1",
            userID: "member-1",
            name: "成员一",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "",
            enterprise: "",
            avatarSeed: 1,
            badges: []
        )
        let memberTwo = IMUser(
            id: "u2",
            userID: "member-2",
            name: "成员二",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "",
            enterprise: "",
            avatarSeed: 2,
            badges: []
        )
        var message = makeMessage(
            id: "m1",
            seq: 1,
            isOutgoing: true,
            text: "当前群成员总数：128 人",
            kind: .system
        )
        message.readCount = 17
        message.unreadCount = 111
        message.quote = "群人数：128 人"
        message.readBy = [
            ReadReceipt(id: "u1", user: memberOne, device: "", time: "10:00")
        ]
        message.unreadBy = [
            ReadReceipt(id: "u2", user: memberTwo, device: "", time: "")
        ]
        var conversation = makeConversation(
            id: "group-1",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.memberCount = 128
        conversation.subtitle = "128 人"
        conversation.lastMessage = "群人数：128 人"
        conversation.mentionSummaryText = "当前群成员总数：128 人"
        conversation.participants = [memberOne]
        conversation.messages = [message]

        let scrubbed = conversation.scrubbingGroupMemberTotals()

        XCTAssertNil(scrubbed.memberCount)
        XCTAssertFalse(scrubbed.subtitle.contains("128"))
        XCTAssertFalse(scrubbed.lastMessage.contains("128"))
        XCTAssertFalse(scrubbed.mentionSummaryText.contains("128"))
        XCTAssertEqual(scrubbed.participants.count, 1)
        XCTAssertNil(scrubbed.messages[0].readCount)
        XCTAssertNil(scrubbed.messages[0].unreadCount)
        XCTAssertEqual(scrubbed.messages[0].readBy.count, 1)
        XCTAssertEqual(scrubbed.messages[0].unreadBy.count, 1)
        XCTAssertFalse(scrubbed.messages[0].text.contains("128"))
        XCTAssertFalse(scrubbed.messages[0].quote?.contains("128") == true)
    }

    func testFriendRelationV2NormalizesPendingEstablishedAndTerminalOutcomes() {
        XCTAssertEqual(
            AppState.friendApplyResolution(
                outcome: "application_created",
                relationStatus: "pending_out",
                status: "pending",
                directlyEstablished: false
            ),
            .pending
        )
        XCTAssertEqual(
            AppState.friendApplyResolution(
                outcome: "application_suppressed",
                relationStatus: "pending_out",
                status: "suppressed",
                directlyEstablished: false
            ),
            .terminal
        )
        XCTAssertEqual(
            AppState.friendApplyResolution(
                outcome: "friendship_established",
                relationStatus: "friend",
                status: "accepted",
                directlyEstablished: false
            ),
            .established
        )
        for status in ["rejected", "cancelled", "expired"] {
            XCTAssertEqual(
                AppState.friendApplyResolution(
                    outcome: "",
                    relationStatus: "history",
                    status: status,
                    directlyEstablished: false
                ),
                .terminal,
                "status=\(status)"
            )
        }
        XCTAssertEqual(
            AppState.friendApplyResolution(
                outcome: "",
                relationStatus: "",
                status: "",
                directlyEstablished: true
            ),
            .established
        )
    }

    func testDirectFriendRequestContextUsesPerTargetActionWithoutLegacyGlobalGate() {
        let context = DirectFriendRequestContext(
            targetUID: "peer-1",
            canApplyFriend: nil,
            friendRequestStatus: "",
            reasonCode: "friendship_required"
        )
        let explicitRequest = DirectFriendRequestContext(
            targetUID: "peer-2",
            canApplyFriend: false,
            friendRequestStatus: "",
            reasonCode: "friendship_required",
            friendAction: "request"
        )
        let unavailable = DirectFriendRequestContext(
            targetUID: "service-1",
            canApplyFriend: true,
            friendRequestStatus: "",
            reasonCode: "target_type_not_allowed",
            friendAction: "none"
        )

        XCTAssertTrue(context.allowsApply)
        XCTAssertTrue(explicitRequest.allowsApply)
        XCTAssertFalse(unavailable.allowsApply)
        XCTAssertEqual(context.actionTitle, "添加好友")
    }

    func testFriendRelationV2RealtimeAndSuppressedClassifiers() {
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application.created", kind: ""))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application.reviewed", kind: ""))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application.rejected", kind: ""))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_relation.established", kind: "friend_relation"))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application_created", kind: "friend"))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application_suppressed", kind: ""))
        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_relation_established", kind: ""))
        XCTAssertFalse(AppState.isFriendRelationRealtimeEvent(event: "group_member_joined", kind: "group"))
        XCTAssertTrue(AppState.isSuppressedFriendApplication(status: "suppressed", outcome: ""))
        XCTAssertTrue(AppState.isSuppressedFriendApplication(status: "pending", outcome: "application_suppressed"))
        XCTAssertFalse(AppState.isSuppressedFriendApplication(status: "pending", outcome: "application_created"))
        XCTAssertTrue(AppState.isFriendRelationChangedConflictCode(" friend_relation_changed "))
        XCTAssertFalse(AppState.isFriendRelationChangedConflictCode("friend_application_exists"))
    }

    func testOutgoingFriendRequestNeverLeaksTenantReviewState() {
        let request = FriendRequest(
            id: "request-1",
            name: "目标用户",
            source: "我发出的申请",
            message: "等待对方通过",
            status: "pending",
            direction: "outgoing",
            tenantReviewStatus: "pending",
            canRespond: false,
            outcome: "application_created",
            relationStatus: "pending_out",
            friendAction: "request",
            friendFlow: "ordinary_to_ordinary",
            requiresTenantReview: true,
            requiresTargetApproval: true,
            accepted: false
        )

        XCTAssertEqual(request.statusLabel, "等待对方通过")
        XCTAssertEqual(request.message, "等待对方通过")
        XCTAssertEqual(FriendAddPresentation.actionTitle, "添加好友")
        XCTAssertEqual(FriendAddPresentation.sentMessage, "申请已发送，等待对方通过")
        XCTAssertEqual(FriendAddPresentation.relationChangedMessage, "好友关系已更新，请查看最新状态")
    }

    func testIOSNeverPresentsSelfOrPeerPresenceStatus() {
        let visiblePolicy = RemoteTenantClientPolicy(showOnlineStatus: true)
        let hiddenPolicy = RemoteTenantClientPolicy(showOnlineStatus: false)

        for status in ["online", "offline", "away", "busy", "dnd", "hidden", "unknown", "expired", "reconnecting", "normal", ""] {
            for online in [true, false, nil] as [Bool?] {
                XCTAssertEqual(
                    AppState.presenceStatusText(rawStatus: status, online: online, policy: visiblePolicy),
                    "",
                    "iOS must not present presence status=\(status) online=\(String(describing: online))"
                )
            }
            XCTAssertNil(presenceBadgeColor(for: status), "iOS must not render a presence badge for \(status)")
        }
        XCTAssertEqual(AppState.presenceStatusText(rawStatus: "online", online: true, policy: hiddenPolicy), "")
        XCTAssertEqual(AppState.presenceStatusText(rawStatus: "online", online: true, policy: nil), "")
    }

    func testIOSNeverPresentsPresenceDerivedLastLogin() {
        XCTAssertNil(AppState.lastLoginPresentationText(rawValue: "今天 09:18", policy: nil))
        XCTAssertNil(AppState.lastLoginPresentationText(rawValue: "今天 09:18", policy: RemoteTenantClientPolicy(showLastLoginTime: false)))
        XCTAssertNil(AppState.lastLoginPresentationText(rawValue: "  ", policy: RemoteTenantClientPolicy(showLastLoginTime: true)))
        XCTAssertNil(
            AppState.lastLoginPresentationText(rawValue: " 今天 09:18 ", policy: RemoteTenantClientPolicy(showLastLoginTime: true)),
            "iOS must not expose peer last-seen through the legacy policy"
        )
    }

    func testIOSUserPresenceSurfacesContainNoPresenceUIOrPlaceholder() throws {
        let iosChatRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = iosChatRoot.appendingPathComponent("BlueStoneIM", isDirectory: true)
        let forbiddenTokensByFile: [String: [String]] = [
            "ConversationViews.swift": [
                "presenceBadgeColor(for:",
                "directStatusBadgeColor",
                "projectPresenceConnectivity(item)",
                "badgeColor: IMColor.success"
            ],
            "ChatViews.swift": [
                "directPresenceSubtitleText",
                "chat_direct_presence_status",
                "presenceBadgeColor(for:",
                "user.status.isEmpty ? \"联系人\" : user.status"
            ],
            "ContactsViews.swift": [
                "presenceBadgeColor(for:",
                "profilePresenceColor",
                "profileStatusText",
                "profileLastLoginText",
                "ProfileInfoRow(title: \"最近登录\""
            ],
            "MeSettingsViews.swift": ["badgeColor: IMColor.success"],
            "FilesRTCViews.swift": ["badgeColor: peer.isCancelledUser ? nil : IMColor.success", "badgeColor: user.isCancelledUser ? nil : IMColor.success", "badgeColor: caller.isCancelledUser ? nil : IMColor.success"],
            "VideoCallViews.swift": ["badgeColor: IMColor.success"],
            "BlueStoneIMApp.swift": ["presenceSummary", "lastLoginCard", "presenceRow("]
        ]

        for (file, forbiddenTokens) in forbiddenTokensByFile {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(file) still contains presence UI token: \(token)")
            }
        }
    }

    func testPresenceUIHidingPreservesBackgroundRealtimeTerminalSignal() {
        let realtime = DeviceKickRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true

        state.appDidEnterBackground()

        XCTAssertEqual(realtime.disconnectCalls, [false])
    }

    func testRealtimePresenceIsConsumedWithoutProjectingIntoUserModels() {
        let state = AppState(
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        state.contacts = [
            IMUser(
                id: "peer-1",
                name: "Peer",
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "cancelled",
                lastLoginAt: "preserved-nonpresentation-value",
                enterprise: "",
                avatarSeed: 0,
                badges: []
            )
        ]

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "notification",
                requestID: nil,
                payload: [
                    "event": .string("presence.connectivity.updated"),
                    "event_type": .string("presence.connectivity.updated"),
                    "tenant_id": .string("tenant-1"),
                    "subject_type": .string("user"),
                    "subject_id": .string("peer-1"),
                    "subject_im_uid": .string("peer-1"),
                    "im_uid": .string("peer-1"),
                    "session_epoch": .string("epoch-a"),
                    "presence_status": .string("online"),
                    "online": .bool(true),
                    "presence_revision": .int(2),
                    "realtime_generation": .int(3),
                    "last_seen_at": .string("2026-08-24T06:40:00Z"),
                    "occurred_at": .string("2026-08-24T06:40:01Z")
                ]
            )
        )

        XCTAssertEqual(state.contacts.first?.status, "cancelled")
        XCTAssertEqual(state.contacts.first?.lastLoginAt, "preserved-nonpresentation-value")
        XCTAssertTrue(state.contacts.first?.isCancelledUser == true)
    }

    func testResolvedCurrentUserUsernamePrefersRemoteThenFallbackThenCurrent() {
        XCTAssertEqual(
            resolvedCurrentUserUsername(remoteUsername: " remote1 ", fallbackUsername: "fallback1", currentUsername: "current1"),
            "remote1"
        )
        XCTAssertEqual(
            resolvedCurrentUserUsername(remoteUsername: " \n ", fallbackUsername: " admin1 ", currentUsername: ""),
            "admin1"
        )
        XCTAssertEqual(
            resolvedCurrentUserUsername(remoteUsername: "", fallbackUsername: nil, currentUsername: " existing1 "),
            "existing1"
        )
        XCTAssertEqual(
            resolvedCurrentUserUsername(remoteUsername: "", fallbackUsername: " ", currentUsername: " "),
            ""
        )
    }

    func testSystemInboxDoesNotOverwriteNewerRemoteConversationSnapshot() {
        XCTAssertTrue(shouldPreserveNewerSystemConversationSnapshot(previousSortTimestamp: 200, latestInboxSortTimestamp: 100))
        XCTAssertTrue(shouldPreserveNewerSystemConversationSnapshot(previousSortTimestamp: 200, latestInboxSortTimestamp: 0))
        XCTAssertFalse(shouldPreserveNewerSystemConversationSnapshot(previousSortTimestamp: 100, latestInboxSortTimestamp: 200))
        XCTAssertFalse(shouldPreserveNewerSystemConversationSnapshot(previousSortTimestamp: 100, latestInboxSortTimestamp: 100))
        XCTAssertFalse(shouldPreserveNewerSystemConversationSnapshot(previousSortTimestamp: 0, latestInboxSortTimestamp: 100))
    }

    func testWenxinUserIDLikeTokenAcceptsOnlyFrozenUserIDFormats() {
        XCTAssertTrue(isWenxinUserIDLikeToken("WXT12345678"))
        XCTAssertTrue(isWenxinUserIDLikeToken(" WXTAB123456 "))
        XCTAssertTrue(isWenxinUserIDLikeToken("AB-U000001"))
        XCTAssertTrue(isWenxinUserIDLikeToken("ABCD-U000001"))

        XCTAssertFalse(isWenxinUserIDLikeToken("WXTABCD1234"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXT1234567"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXT123456789"))
        XCTAssertFalse(isWenxinUserIDLikeToken("wxt12345678"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXTab123456"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXT1A123456"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXTABC12345"))
        XCTAssertFalse(isWenxinUserIDLikeToken("WXT-U000001"))
        XCTAssertFalse(isWenxinUserIDLikeToken("YQM-U000001"))
        XCTAssertFalse(isWenxinUserIDLikeToken("ＡＢ-U000001"))
    }

    func testRealNameValidatorKeepsChineseNameAndRejectsLatinName() {
        XCTAssertEqual(RealNameValidator.sanitizedName(" 张三 "), "张三")
        XCTAssertTrue(RealNameValidator.isValidName("张三"))
        XCTAssertTrue(RealNameValidator.isValidName("欧阳娜娜"))
        XCTAssertFalse(RealNameValidator.isValidName("zhangsan"))
    }

    func testRealNameValidatorAccepts15Or18DigitResidentID() {
        XCTAssertTrue(RealNameValidator.isValidChineseResidentID("110105491231002"))
        XCTAssertTrue(RealNameValidator.isValidChineseResidentID("11010519491231002X"))
        XCTAssertFalse(RealNameValidator.isValidChineseResidentID("11010549123100X"))
        XCTAssertFalse(RealNameValidator.isValidChineseResidentID("11010519491231002"))
    }

    func testSupportContactMailtoBuildsSafeURL() {
        let url = SupportContactMailto.mailtoURL(email: " support+ios@example.com ")

        XCTAssertEqual(url?.absoluteString, "mailto:support+ios@example.com")
    }

    func testSupportContactMailtoRejectsEmptyOrUnsafeEmail() {
        XCTAssertNil(SupportContactMailto.mailtoURL(email: ""))
        XCTAssertNil(SupportContactMailto.mailtoURL(email: "support example@example.com"))
        XCTAssertNil(SupportContactMailto.mailtoURL(email: "support@example.com?subject=test"))
        XCTAssertNil(SupportContactMailto.mailtoURL(email: "support@example"))
    }

    func testSplashImageDiskCacheKeyPrefersAssetVersionAndFallsBackToURL() {
        let assetKey = SplashImageDiskCache.cacheKey(
            assetID: "asset-1",
            version: "v1",
            imageURL: "https://cdn.example.test/old.png"
        )
        let assetKeyWithOtherURL = SplashImageDiskCache.cacheKey(
            assetID: "asset-1",
            version: "v1",
            imageURL: "https://cdn.example.test/new.png"
        )
        let nextVersionKey = SplashImageDiskCache.cacheKey(
            assetID: "asset-1",
            version: "v2",
            imageURL: "https://cdn.example.test/old.png"
        )
        let fallbackURLKey = SplashImageDiskCache.cacheKey(
            assetID: "",
            version: "v1",
            imageURL: "https://cdn.example.test/fallback.png"
        )
        let explicitKey = SplashImageDiskCache.cacheKey(explicitKey: "tenant-1/asset-1/v1")
        let explicitKeyWithWhitespace = SplashImageDiskCache.cacheKey(explicitKey: " tenant-1/asset-1/v1 ")

        XCTAssertEqual(assetKey, assetKeyWithOtherURL)
        XCTAssertNotEqual(assetKey, nextVersionKey)
        XCTAssertNotNil(fallbackURLKey)
        XCTAssertEqual(explicitKey, explicitKeyWithWhitespace)
        XCTAssertNotEqual(explicitKey, assetKey)
        XCTAssertNil(SplashImageDiskCache.cacheKey(assetID: "asset-1", version: "", imageURL: "https://cdn.example.test/a.png"))
        XCTAssertNil(SplashImageDiskCache.cacheKey(explicitKey: " "))
    }

    func testSplashImageCoverLayoutAlwaysCoversContainer() {
        let portraitAsset = CGSize(width: 1080, height: 1920)
        let containers = [
            CGSize(width: 1080, height: 2520),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390)
        ]

        for container in containers {
            let layout = SplashImageCoverLayout.layout(imageSize: portraitAsset, containerSize: container)

            XCTAssertGreaterThanOrEqual(layout.renderedSize.width + 0.5, container.width)
            XCTAssertGreaterThanOrEqual(layout.renderedSize.height + 0.5, container.height)
        }
    }

    func testSplashSnapshotStoreRequiresDiskImageAndKeepsTenantsIsolated() throws {
        let suiteName = "BlueStoneIMTests.splash.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1")
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)

        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.snapshot(tenantID: "tenant-2", defaults: defaults))

        let cacheKey = try XCTUnwrap(snapshot.cacheKey)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKey))
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-2", cache: cache, defaults: defaults))

        SplashSnapshotStore.disableSnapshot(tenantID: "tenant-1", reason: "license_disabled", defaults: defaults)
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
        XCTAssertTrue(cache.containsImage(for: cacheKey))
    }

    func testSplashTenantScopeSeparatesAppAccountTenantAndNormalizedAPIOrigin() {
        let base = SplashTenantScope(
            appID: " app-main ",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "HTTPS://TENANT-A.EXAMPLE.TEST/api/tenant/"
        )
        let normalized = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test:443/api/tenant"
        )

        XCTAssertTrue(base.isValid)
        XCTAssertEqual(base, normalized)
        XCTAssertEqual(base.tenantOrigin, "https://tenant-a.example.test:443/api/tenant")
        XCTAssertEqual(base.storageKey, normalized.storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-secondary",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-2",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-2",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test:8443/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/other"
        ).storageKey)
    }

    func testColdLaunchSplashCanReplaceLaunchOrRestoreButNeverCoverInteractiveUI() {
        XCTAssertTrue(canPresentColdLaunchSplash(
            hasMainShellBecomeInteractive: false
        ))
        XCTAssertFalse(canPresentColdLaunchSplash(
            hasMainShellBecomeInteractive: true
        ))
    }

    func testSplashSkipPolicyHonorsMinimumShowDuration() {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertFalse(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 1_200,
            now: startedAt.addingTimeInterval(1.199)
        ))
        XCTAssertTrue(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 1_200,
            now: startedAt.addingTimeInterval(1.2)
        ))
        XCTAssertTrue(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 0,
            now: startedAt
        ))
    }

    func testSplashRefreshCandidateRejectsLateTenantAndVersionResponses() throws {
        let suiteName = "BlueStoneIMTests.splash.candidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "asset-a",
            version: "a-1"
        )
        let snapshotB1 = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-1"
        )
        let candidateA = try XCTUnwrap(SplashRefreshCandidate(
            generation: 1,
            scope: scopeA,
            snapshot: snapshotA
        ))
        XCTAssertNil(SplashRefreshCandidate(
            generation: 0,
            scope: scopeA,
            snapshot: snapshotA
        ))
        let candidateB1 = try XCTUnwrap(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: snapshotB1
        ))
        SplashSnapshotStore.saveSnapshot(snapshotB1, scope: scopeB, defaults: defaults)

        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertTrue(candidateB1.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))

        let disabledB = snapshotB1.disabled(reason: "config_disabled")
        SplashSnapshotStore.saveSnapshot(disabledB, scope: scopeB, defaults: defaults)
        XCTAssertFalse(disabledB.isConfigDisplayable)
        XCTAssertNil(SplashRefreshCandidate(
            generation: 3,
            scope: scopeB,
            snapshot: disabledB
        ))

        let snapshotB2 = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-2"
        )
        SplashSnapshotStore.saveSnapshot(snapshotB2, scope: scopeB, defaults: defaults)
        XCTAssertFalse(candidateB1.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertFalse(SplashSnapshotStore.updatePrefetchStatus(
            candidate: candidateB1,
            status: .downloaded,
            defaults: defaults
        ))
        XCTAssertEqual(
            SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)?.normalizedVersion,
            "b-2"
        )
    }

    func testScopedSplashSnapshotAndImageCacheNeverCrossTenants() throws {
        let suiteName = "BlueStoneIMTests.splash.scoped.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.scoped.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "shared-asset",
            version: "1",
            cacheKeyOverride: "shared-asset:1"
        )
        let snapshotB = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "shared-asset",
            version: "1",
            cacheKeyOverride: "shared-asset:1"
        )
        SplashSnapshotStore.saveSnapshot(snapshotA, scope: scopeA, defaults: defaults)
        SplashSnapshotStore.saveSnapshot(snapshotB, scope: scopeB, defaults: defaults)

        let cacheKeyA = try XCTUnwrap(snapshotA.cacheKey(scope: scopeA))
        let cacheKeyB = try XCTUnwrap(snapshotB.cacheKey(scope: scopeB))
        XCTAssertNotEqual(cacheKeyA, cacheKeyB)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyA))
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(scope: scopeA, cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scopeB, cache: cache, defaults: defaults))

        SplashSnapshotStore.disableSnapshot(scope: scopeB, reason: "config_disabled", defaults: defaults)
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(scope: scopeA, cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scopeB, cache: cache, defaults: defaults))
    }

    func testSplashTenantSwitchOnlyPresentsCurrentConfirmedTenant() throws {
        let suiteName = "BlueStoneIMTests.splash.tenant-switch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.tenant-switch.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "asset-a",
            version: "a-1"
        )
        let snapshotB = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-1"
        )
        SplashSnapshotStore.saveSnapshot(snapshotA, scope: scopeA, defaults: defaults)
        let cacheKeyA = try XCTUnwrap(snapshotA.cacheKey(scope: scopeA))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyA))
        let candidateA = try XCTUnwrap(SplashRefreshCandidate(
            generation: 1,
            scope: scopeA,
            snapshot: snapshotA
        ))
        XCTAssertEqual(
            SplashSnapshotStore.displayableSnapshot(
                scope: scopeA,
                cache: cache,
                defaults: defaults
            )?.tenantID,
            "tenant-a"
        )

        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(
            scope: scopeB,
            cache: cache,
            defaults: defaults
        ))

        let disabledB = snapshotB.disabled(reason: "splash_config_disabled")
        SplashSnapshotStore.saveSnapshot(disabledB, scope: scopeB, defaults: defaults)
        XCTAssertNil(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: disabledB
        ))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(
            scope: scopeB,
            cache: cache,
            defaults: defaults
        ))

        SplashSnapshotStore.saveSnapshot(snapshotB, scope: scopeB, defaults: defaults)
        let cacheKeyB = try XCTUnwrap(snapshotB.cacheKey(scope: scopeB))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyB))
        let candidateB = try XCTUnwrap(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: snapshotB
        ))
        XCTAssertTrue(candidateB.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertEqual(
            SplashSnapshotStore.displayableSnapshot(
                scope: scopeB,
                cache: cache,
                defaults: defaults
            )?.tenantID,
            "tenant-b"
        )
    }

    func testScopedSplashStoreDoesNotTrustLegacyTenantOnlySnapshot() throws {
        let suiteName = "BlueStoneIMTests.splash.no-legacy-fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.no-legacy-fallback.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshot = testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1")
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        let legacyCacheKey = try XCTUnwrap(snapshot.cacheKey)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: legacyCacheKey))

        let scoped = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant.example.test/api/tenant"
        )
        XCTAssertNil(SplashSnapshotStore.snapshot(scope: scoped, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scoped, cache: cache, defaults: defaults))
    }

    func testSplashSnapshotStoreUsesExplicitCacheKeyWhenProvided() throws {
        let suiteName = "BlueStoneIMTests.splash.explicit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.explicit.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let explicitRawKey = "tenant-1/asset-stage4/v4"
        let snapshot = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-stage4",
            version: "v4",
            cacheKeyOverride: explicitRawKey
        )
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)

        let assetVersionKey = try XCTUnwrap(SplashImageDiskCache.cacheKey(
            assetID: "asset-stage4",
            version: "v4",
            imageURL: "https://cdn.example.test/splash.png"
        ))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: assetVersionKey))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let explicitCacheKey = try XCTUnwrap(SplashImageDiskCache.cacheKey(explicitKey: explicitRawKey))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: explicitCacheKey))
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
    }

    func testSplashImageDiskCachePrefetchesFileURLAndRejectsInvalidData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory.appendingPathComponent("cache", isDirectory: true))
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("splash.png", isDirectory: false)
        let invalidURL = directory.appendingPathComponent("splash.txt", isDirectory: false)
        try testSplashPNGData().write(to: imageURL)
        try Data("not-image".utf8).write(to: invalidURL)

        let status = await cache.prefetchImage(from: imageURL.absoluteString, cacheKey: "file-success")
        let invalidStatus = await cache.prefetchImage(from: invalidURL.absoluteString, cacheKey: "file-invalid")

        XCTAssertEqual(status, .downloaded)
        XCTAssertTrue(cache.containsImage(for: "file-success"))
        XCTAssertEqual(invalidStatus, .failed)
        XCTAssertFalse(cache.containsImage(for: "file-invalid"))
    }

    func testSplashImageValidatorAcceptsFrozenPNGJPEGAndWebPContract() throws {
        let png = testSplashPNGData(width: 2, height: 3)
        let jpeg = try XCTUnwrap(testSplashImage(width: 2, height: 3).jpegData(compressionQuality: 0.9))
        let webP = try XCTUnwrap(Data(
            base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA=="
        ))
        let fixtures: [(name: String, data: Data, mimeType: String, width: Int, height: Int)] = [
            ("splash.png", png, "image/png", 2, 3),
            ("splash.jpg", jpeg, "image/jpeg", 2, 3),
            ("splash.webp", webP, "image/webp", 1, 1)
        ]

        for fixture in fixtures {
            let result = SplashImageValidator.validate(
                data: fixture.data,
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(fixture.name),
                expectedSHA256: splashSHA256Hex(fixture.data),
                expectedSizeBytes: Int64(fixture.data.count),
                expectedMimeType: fixture.mimeType,
                expectedWidth: fixture.width,
                expectedHeight: fixture.height
            )
            guard case .valid(let preparedImage) = result else {
                XCTFail("Expected valid \(fixture.mimeType) splash image")
                continue
            }
            XCTAssertEqual(preparedImage.mimeType, fixture.mimeType)
            XCTAssertEqual(preparedImage.sizeBytes, Int64(fixture.data.count))
            XCTAssertEqual(preparedImage.width, fixture.width)
            XCTAssertEqual(preparedImage.height, fixture.height)
            XCTAssertEqual(preparedImage.sha256Hex, splashSHA256Hex(fixture.data))
        }
    }

    func testSplashImageValidatorRejectsIntegrityAndSafetyViolations() {
        let data = testSplashPNGData(width: 2, height: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splash.png")

        assertSplashValidationFailure(.checksumMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedSHA256: String(repeating: "0", count: 64)
        ))
        assertSplashValidationFailure(.sizeMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedSizeBytes: Int64(data.count + 1)
        ))
        assertSplashValidationFailure(.mimeTypeMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedMimeType: "image/jpeg"
        ))
        assertSplashValidationFailure(.dimensionsMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedWidth: 3,
            expectedHeight: 3
        ))
        assertSplashValidationFailure(.fileTooLarge, result: SplashImageValidator.validate(
            data: Data(repeating: 0, count: SplashImageValidator.maxSizeBytes + 1),
            fileURL: url
        ))
        let tooWide = testSplashPNGData(width: SplashImageValidator.maxWidth + 1, height: 1)
        assertSplashValidationFailure(.dimensionsOutOfRange, result: SplashImageValidator.validate(
            data: tooWide,
            fileURL: url
        ))
        assertSplashValidationFailure(.unsupportedFormat, result: SplashImageValidator.validate(
            data: Data("not-an-image".utf8),
            fileURL: url
        ))
    }

    func testSplashImagePreparationDeletesCacheThatFailsExpectedIntegrity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.bad-cache.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory.appendingPathComponent("cache", isDirectory: true))
        let sourceURL = directory.appendingPathComponent("source.png", isDirectory: false)
        let cacheKey = "strict-cache"
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let data = testSplashPNGData(width: 2, height: 3)
        try data.write(to: sourceURL)
        try data.write(to: cache.fileURL(for: cacheKey))

        let result = await cache.prepareImage(
            from: sourceURL.absoluteString,
            cacheKey: cacheKey,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedSizeBytes: Int64(data.count),
            expectedMimeType: "image/png",
            expectedWidth: 2,
            expectedHeight: 3
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailure, .checksumMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: cacheKey).path))
    }

    func testSplashSnapshotStoreClearsTenantAndAllSnapshots() throws {
        let suiteName = "BlueStoneIMTests.splash.clear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        SplashSnapshotStore.saveSnapshot(testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1"), defaults: defaults)
        SplashSnapshotStore.saveSnapshot(testSplashSnapshot(tenantID: "tenant-2", assetID: "asset-2", version: "v1"), defaults: defaults)

        SplashSnapshotStore.clearTenant("tenant-1", defaults: defaults)
        XCTAssertNil(SplashSnapshotStore.snapshot(tenantID: "tenant-1", defaults: defaults))
        XCTAssertNotNil(SplashSnapshotStore.snapshot(tenantID: "tenant-2", defaults: defaults))

        SplashSnapshotStore.clearAll(defaults: defaults)
        XCTAssertTrue(SplashSnapshotStore.snapshots(defaults: defaults).isEmpty)
        XCTAssertTrue(SplashSnapshotStore.displayStates(defaults: defaults).isEmpty)
    }

    func testSplashDisplayStateAllowsRepeatedColdStartsButHonorsLaunchOnce() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-1",
            version: "v1",
            minIntervalSec: 14_400,
            dailyCap: 3
        )
        let shown = SplashDisplayState.empty.recordingShown(snapshot: snapshot, at: now)

        XCTAssertFalse(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(60), isColdStartLike: false, alreadyShownInThisLaunch: false))
        XCTAssertTrue(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
        XCTAssertFalse(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(14_400), isColdStartLike: true, alreadyShownInThisLaunch: true))
        XCTAssertTrue(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(14_400), isColdStartLike: true, alreadyShownInThisLaunch: false))
    }

    func testSplashDisplayStateIgnoresDailyCapAndMinInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-1",
            version: "v1",
            minIntervalSec: 14_400,
            dailyCap: 1
        )
        let second = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-2",
            version: "v2",
            minIntervalSec: 14_400,
            dailyCap: 1
        )
        let shown = SplashDisplayState.empty.recordingShown(snapshot: first, at: now)

        XCTAssertTrue(shown.canPresent(snapshot: first, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
        XCTAssertTrue(shown.canPresent(snapshot: second, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
    }

    func testSplashSnapshotStoreRecordsBackgroundTimePerTenant() throws {
        let suiteName = "BlueStoneIMTests.splash.background.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let backgroundedAt = Date(timeIntervalSince1970: 2_000_123_456)

        SplashSnapshotStore.recordBackgrounded(tenantID: "tenant-1", at: backgroundedAt, defaults: defaults)

        XCTAssertEqual(
            SplashSnapshotStore.displayState(tenantID: "tenant-1", defaults: defaults).lastBackgroundedAt,
            backgroundedAt.timeIntervalSince1970
        )
        XCTAssertNil(SplashSnapshotStore.displayState(tenantID: "tenant-2", defaults: defaults).lastBackgroundedAt)
    }

    func testSplashInitialEvaluationKeepsOpportunityUntilSnapshotAndCacheReady() throws {
        XCTAssertTrue(SplashOverlayEvaluationResult.notReadyNoSnapshot.keepsInitialEvaluationPending)
        XCTAssertTrue(SplashOverlayEvaluationResult.notReadyNoCache.keepsInitialEvaluationPending)
        XCTAssertFalse(SplashOverlayEvaluationResult.blockedByPolicy("already_shown_in_activation").keepsInitialEvaluationPending)
        XCTAssertFalse(SplashOverlayEvaluationResult.shown.keepsInitialEvaluationPending)

        let suiteName = "BlueStoneIMTests.splash.initial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.initial.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let snapshot = testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1")
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let cacheKey = try XCTUnwrap(snapshot.cacheKey)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKey))
        let displayable = try XCTUnwrap(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
        XCTAssertTrue(SplashDisplayState.empty.canPresent(
            snapshot: displayable,
            isColdStartLike: true,
            alreadyShownInThisLaunch: false
        ))
    }

    private func testSplashImage(width: Int = 1, height: Int = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func testSplashPNGData(width: Int = 1, height: Int = 1) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func splashSHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func assertSplashValidationFailure(
        _ expected: SplashImageValidationFailure,
        result: SplashImageValidationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .invalid(let actual) = result else {
            XCTFail("Expected splash validation failure \(expected.rawValue)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func testSplashSnapshot(
        tenantID: String,
        assetID: String,
        version: String,
        cacheKeyOverride: String? = nil,
        minIntervalSec: Int? = 3600,
        dailyCap: Int? = 1
    ) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: true,
            splashEnabled: true,
            assetID: assetID,
            imageURL: "https://cdn.example.test/splash.png",
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: 1170,
            height: 2532,
            mimeType: "image/png",
            sizeBytes: 128,
            etag: "etag",
            sha256: "sha",
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: 800,
            maxShowMS: 3000,
            actionURL: "",
            fetchedAt: Date().timeIntervalSince1970,
            disabledReason: "",
            prefetchStatus: .pending,
            lastPrefetchAt: nil,
            lastPrefetchError: ""
        )
    }

    func testCurrentUserIdentityCacheRestoresUsernameAndClearsByScope() throws {
        let suiteName = "BlueStoneIMTests.identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "im-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        )
        let user = IMUser(
            id: "im-1",
            userID: "user-1",
            username: " admin1 ",
            name: "赵悦",
            title: "",
            department: "",
            phone: "",
            email: "account-1",
            status: "在线",
            enterprise: "Local Tenant",
            avatarSeed: 42,
            avatarURL: "https://example.test/avatar.png",
            badges: []
        )

        let authorityScope = CurrentProfileAuthorityScope(
            tenantID: "tenant-1",
            actorIMUID: "im-1",
            appID: "ios-main"
        )!
        let authorityCheckpoint = CurrentProfileAuthorityCheckpoint(
            scope: authorityScope,
            userRevision: 8,
            identityGeneration: 13,
            nickname: "赵悦",
            avatar: "https://example.test/avatar.png"
        )

        IMCurrentUserIdentityCache.save(
            user,
            context: context,
            profileAuthorityCheckpoint: authorityCheckpoint,
            defaults: defaults
        )
        let stored = try XCTUnwrap(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
        let restored = stored.makeUser(fallbackEnterprise: "Fallback Tenant", fallbackSeed: 1)

        XCTAssertEqual(restored.username, "admin1")
        XCTAssertEqual(restored.name, "赵悦")
        XCTAssertEqual(restored.enterprise, "Local Tenant")
        XCTAssertEqual(restored.avatarSeed, 42)
        XCTAssertEqual(stored.authorityCheckpoint, authorityCheckpoint)

        let otherAppContext = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "im-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-app2",
            deviceID: "device-1"
        )
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: otherAppContext, defaults: defaults))

        IMCurrentUserIdentityCache.clear(context: context, defaults: defaults)
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
    }

    func testAppStateRefreshCurrentEnterpriseProfileAppliesRenamedTenantAndLogo() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        let oldEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "成员",
            status: "正常",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF,
            logoURL: "https://tenant.example.test/api/tenant/avatar/logo-v1.png",
            logoStatus: "ready",
            logoVersion: "logo-v1",
            logoUpdatedAt: "2026-06-26T10:00:00Z",
            logoCacheKey: "logo-v1"
        )
        state.isAuthenticated = true
        state.currentEnterprise = oldEnterprise
        state.enterprises = [oldEnterprise]
        state.currentUser = IMUser(
            id: "uid-1",
            userID: "account-1",
            username: "admin1",
            name: "赵悦",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "旧企业",
            avatarSeed: 0x5D6BFF,
            badges: []
        )

        let updated = await state.refreshCurrentEnterpriseProfile(silent: false)

        XCTAssertTrue(updated)
        XCTAssertEqual(state.currentEnterprise.name, "后台改名企业")
        XCTAssertEqual(state.currentEnterprise.code, "WXT000001")
        XCTAssertEqual(state.currentEnterprise.logoURL, "https://tenant.example.test/api/tenant/avatar/logo-v2.png")
        XCTAssertEqual(state.currentEnterprise.logoCacheKey, "logo-v2")
        XCTAssertEqual(state.currentUser.enterprise, "后台改名企业")
        let requestPaths = transport.requestPaths()
        XCTAssertTrue(requestPaths.contains("/api/tenant/profile"))
        XCTAssertTrue(requestPaths.contains("/api/tenant/workspaces"))
    }

    func testAppStateRefreshCurrentEnterpriseProfileUsesTenantContextRoleAuthorityForInternalGroupCreation() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport(tenantContextRole: "internal")
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        let staleWorkspaceEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "member",
            status: "normal",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF
        )
        state.isAuthenticated = true
        state.currentEnterprise = staleWorkspaceEnterprise
        state.enterprises = [staleWorkspaceEnterprise]

        XCTAssertFalse(state.canCreateGroupChat)
        let firstRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(firstRefresh)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.canCreateGroupChat)

        // A later workspace refresh still reports the stale member role. The current
        // tenant-context authority must remain stable and prevent the action from
        // disappearing again.
        let secondRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(secondRefresh)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.canCreateGroupChat)
        XCTAssertEqual(state.enterprises.first(where: { $0.id == "tenant-1" })?.role, "internal")
        XCTAssertEqual(transport.requestPaths().filter { $0 == "/api/tenant/context" }.count, 2)
    }

    func testAppStateProjectsAuthoritativeMultiDeviceBooleanWithoutInventingNumericLimit() async throws {
        let cases: [(String, String)] = [
            (#"{"multi_device_enabled":false,"authoritative":true,"contract_version":1}"#, "1 台设备"),
            (#"{"multi_device_enabled":true,"authoritative":true,"contract_version":1}"#, "允许多设备")
        ]

        for (devicePolicyJSON, expectedText) in cases {
            let transport = EnterpriseProfileRefreshHTTPTransport(
                tenantContextRole: "member",
                tenantContextDevicePolicyJSON: devicePolicyJSON
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let context = IMAPIContext(
                platformToken: "platform-token",
                accountID: "account-1",
                tenantID: "tenant-1",
                imUID: "uid-1",
                imToken: "im-token",
                platformAuthSession: nil,
                tenantAuthSession: nil,
                appID: IMAPIContext.canonicalIOSAppID,
                deviceID: "unit-test-device"
            )
            let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
            let existingDevices = [
                DeviceSession(
                    id: "existing-device",
                    name: "iPhone",
                    platform: "ios",
                    lastSeen: "刚刚",
                    status: "可信设备",
                    isBound: true,
                    isBlocked: false
                )
            ]
            state.isAuthenticated = true
            state.deviceSessions = existingDevices

            let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)
            XCTAssertTrue(refreshed)
            XCTAssertEqual(state.tenantDeviceLimitPresentationText, expectedText)
            XCTAssertEqual(state.deviceSessions, existingDevices)
        }
    }

    func testAppStateKeepsMultiDevicePresentationUnavailableForMalformedAuthority() async throws {
        let malformedPolicies = [
            #"{"multi_device_enabled":true,"contract_version":1}"#,
            #"{"multi_device_enabled":"true","authoritative":true,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":false,"contract_version":1}"#
        ]

        for devicePolicyJSON in malformedPolicies {
            let transport = EnterpriseProfileRefreshHTTPTransport(
                tenantContextRole: "member",
                tenantContextDevicePolicyJSON: devicePolicyJSON
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                apiContextOverride: IMAPIContext(
                    platformToken: "platform-token",
                    accountID: "account-1",
                    tenantID: "tenant-1",
                    imUID: "uid-1",
                    imToken: "im-token",
                    platformAuthSession: nil,
                    tenantAuthSession: nil,
                    appID: IMAPIContext.canonicalIOSAppID,
                    deviceID: "unit-test-device"
                )
            )
            state.isAuthenticated = true

            let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)
            XCTAssertTrue(refreshed)
            XCTAssertEqual(state.tenantDeviceLimitPresentationText, "同步中")
        }
    }

    func testAppStateDropsOlderTenantDevicePolicyResponseWithinSameSession() async throws {
        let gate = FirstReadAckSuspensionGate()
        let transport = TenantDevicePolicyRaceHTTPTransport(firstTenantContextGate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        state.isAuthenticated = true

        let olderRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard await gate.isWaiting() else {
            await gate.resumeFirst()
            olderRefresh.cancel()
            XCTFail("Timed out waiting for the first tenant-context request")
            return
        }

        let newerRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<10 {
            await Task.yield()
        }

        await gate.resumeFirst()
        let newerUpdated = await newerRefresh.value
        let olderUpdated = await olderRefresh.value
        XCTAssertTrue(newerUpdated)
        XCTAssertTrue(olderUpdated)
        XCTAssertEqual(transport.tenantContextRequests(), 1)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "1 台设备")
    }

    func testAppStateInvalidatesTenantDevicePolicyAcrossSessionChangeAndDropsOldResponse() async throws {
        let gate = FirstReadAckSuspensionGate()
        let transport = TenantDevicePolicyRaceHTTPTransport(firstTenantContextGate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        var context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token-old",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        state.isAuthenticated = true

        let olderRefresh = Task { await state.refreshCurrentEnterpriseProfile(silent: false) }
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard await gate.isWaiting() else {
            await gate.resumeFirst()
            olderRefresh.cancel()
            XCTFail("Timed out waiting for the first tenant-context request")
            return
        }

        context.imToken = "im-token-new"
        state.overrideAPIContextForTesting(context)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "同步中")

        let newerRefresh = await state.refreshCurrentEnterpriseProfile(silent: false)
        XCTAssertTrue(newerRefresh)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "允许多设备")

        await gate.resumeFirst()
        _ = await olderRefresh.value
        XCTAssertEqual(transport.tenantContextRequests(), 2)
        XCTAssertEqual(state.tenantDeviceLimitPresentationText, "允许多设备")
    }

    func testAppStateRefreshCurrentEnterpriseProfilePromotesReadyProjectionAdmission() async throws {
        let transport = EnterpriseProfileRefreshHTTPTransport(
            tenantContextRole: "internal",
            workspaceItemsJSON: """
                  {
                    "id": "tenant-1",
                    "tenantCode": "WXT000001",
                    "tenantName": "后台改名企业",
                    "status": "enabled",
                    "join_status": "joined",
                    "member_status": "normal",
                    "member_role": "internal",
                    "can_switch": false,
                    "enterable": false,
                    "current": true,
                    "reason_code": "member_projection_syncing",
                    "reason_text": "enterprise member is syncing",
                    "member_projection_status": "applied",
                    "logo_url": "/api/tenant/avatar/logo-v1.png",
                    "logo_status": "ready",
                    "logo_cache_key": "logo-v1"
                  }
            """
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)
        var staleWorkspaceEnterprise = Enterprise(
            id: "tenant-1",
            name: "旧企业",
            code: "WXT000001",
            role: "member",
            status: "normal",
            memberCount: 0,
            isDefault: true,
            accentHex: 0x5D6BFF
        )
        staleWorkspaceEnterprise.canSwitch = false
        staleWorkspaceEnterprise.enterable = false
        staleWorkspaceEnterprise.tenantStatus = "enabled"
        staleWorkspaceEnterprise.memberStatus = "normal"
        staleWorkspaceEnterprise.disabledReason = "member_projection_syncing"
        state.isAuthenticated = true
        state.authScreen = .workspaceSelection
        state.currentEnterprise = staleWorkspaceEnterprise
        state.enterprises = [staleWorkspaceEnterprise]

        let refreshed = await state.refreshCurrentEnterpriseProfile(silent: false)

        XCTAssertTrue(refreshed)
        let refreshedEnterprise = try XCTUnwrap(state.enterprises.first { $0.id == "tenant-1" })
        XCTAssertEqual(refreshedEnterprise.role, "internal")
        XCTAssertTrue(refreshedEnterprise.canSwitch)
        XCTAssertEqual(refreshedEnterprise.enterable, true)
        XCTAssertTrue(refreshedEnterprise.disabledReason.isEmpty)
        XCTAssertTrue(refreshedEnterprise.isWorkspaceEnterable)
        XCTAssertEqual(state.currentEnterprise.role, "internal")
        XCTAssertTrue(state.currentEnterprise.canSwitch)
        XCTAssertEqual(state.currentEnterprise.enterable, true)
        XCTAssertTrue(state.currentEnterprise.disabledReason.isEmpty)
        XCTAssertTrue(transport.requestPaths().contains("/api/tenant/workspaces"))
    }

    func testAppStatePrepareSearchJumpTargetSyncsAnchorBeforeSeqAndFindsExactMessage() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: """
        [
          {
            "message_id": "msg-42",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "from_uid": "uid-2",
            "sender_display_name": "测试用户",
            "content_type": "text",
            "payload": {"text":"锚点消息"},
            "status": "normal",
            "created_at": "2026-06-27T10:00:00Z"
          }
        ]
        """)
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.conversationStore.conversations = [
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        ]

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-42"
            ),
            conversationID: "group-1"
        )

        XCTAssertEqual(resolved, "msg-42")
        let body = try XCTUnwrap(transport.requestBodies().first)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["before_seq"] as? Int, 43)
    }

    func testAppStatePrepareSearchJumpTargetHydratesPinnedContextOnlyAnchor() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: """
        [
          {
            "message_id": "msg-42",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "from_uid": "uid-2",
            "sender_display_name": "测试用户",
            "content_type": "text",
            "payload": {"text":"搜索命中消息"},
            "status": "normal",
            "created_at": "2026-06-27T10:00:00Z"
          }
        ]
        """)
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var conversation = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        var contextOnly = makeMessage(id: "msg-42", seq: 42, isPinned: true, text: "旧置顶占位")
        contextOnly.isPinnedContextOnly = true
        conversation.messages = [contextOnly]
        state.conversationStore.conversations = [conversation]

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-42"
            ),
            conversationID: "group-1"
        )

        XCTAssertEqual(resolved, "msg-42")
        XCTAssertEqual(transport.requestBodies().count, 1)
        XCTAssertFalse(state.conversations[0].messages[0].isPinnedContextOnly)
    }

    func testAppStatePrepareSearchJumpTargetReturnsNilWhenAnchorStillMissing() async throws {
        let transport = SearchJumpTargetHTTPTransport(syncItemsJSON: "[]")
        let state = AppState(
            api: makeSearchJumpAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.conversationStore.conversations = [
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 0)
        ]

        let resolved = await state.prepareSearchJumpTarget(
            RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: "group-1",
                channelType: "group",
                channelSeq: 42,
                messageID: "msg-missing"
            ),
            conversationID: "group-1"
        )

        XCTAssertNil(resolved)
        let body = try XCTUnwrap(transport.requestBodies().first)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["before_seq"] as? Int, 43)
    }

    func testManualOlderHistoryIsDurableWhenLoadTaskFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-history-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"message_id":"msg-49","channel_id":"group-history","channel_type":"group","channel_seq":49,"from_uid":"uid-2","sender_display_name":"历史用户","content_type":"text","payload":{"text":"即时落库的旧消息"},"status":"normal","created_at":"2026-08-27T10:00:00Z"}],"has_more_before":true,"total":1}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let context = makeAuthenticatedAPIContext()
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let syncEngine = DefaultSyncEngine()
        _ = syncEngine.beginRemoteSnapshotRefresh()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        var conversation = makeConversation(
            id: "group-history",
            kind: .group,
            unread: 0,
            lastMsgSeq: 149,
            lastReadSeq: 149
        )
        conversation.messages = (50...149).map { sequence in
            makeMessage(id: "msg-\(sequence)", seq: Int64(sequence), text: "当前窗口 \(sequence)")
        }
        var signedAttachment = makeMessage(id: "msg-50", seq: 50, text: "当前窗口 50", kind: .file)
        signedAttachment.attachmentPreviewURL = "https://cdn.example.test/preview?auth_key=secret"
        signedAttachment.attachmentDownloadURL = "https://cdn.example.test/download?signature=secret"
        signedAttachment.attachmentThumbnailURL = "https://cdn.example.test/thumb?token=secret"
        conversation.messages[0] = signedAttachment
        conversation.messageCoveredThroughSeq = 149
        state.conversationStore.conversations = [conversation]

        XCTAssertTrue(state.loadOlderMessagesIfAvailable(conversation.id))
        for _ in 0..<200 {
            let hasOldMessage = state.conversations.first?.messages.contains(where: { $0.id == "msg-49" }) == true
            if hasOldMessage && !state.conversationStore.isHistoryLoading(conversationID: conversation.id) {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(state.conversations.first?.messages.contains(where: { $0.id == "msg-49" }) == true)
        XCTAssertFalse(state.conversationStore.isHistoryLoading(conversationID: conversation.id))

        let loaded = try await persistence.activateAndLoad(
            context: context,
            sessionGeneration: 1,
            conversationLimit: 10,
            messagesPerConversation: 200
        )
        let persisted = try XCTUnwrap(loaded.conversations.first(where: { $0.id == conversation.id }))
        XCTAssertEqual(persisted.messages.count, 101)
        XCTAssertTrue(persisted.messages.contains(where: { $0.id == "msg-49" }))
        let persistedAttachment = try XCTUnwrap(persisted.messages.first(where: { $0.id == "msg-50" }))
        XCTAssertEqual(persistedAttachment.attachmentPreviewURL, "")
        XCTAssertEqual(persistedAttachment.attachmentDownloadURL, "")
        XCTAssertEqual(persistedAttachment.attachmentThumbnailURL, "")
    }

    func testManualOlderHistoryRejectsMalformedRTCCollisionBeforeAdvancingCoverage() async throws {
        for field in ["schema_version", "ended_at"] {
            try await assertManualOlderRTCHistoryPage(malformedField: field)
        }
    }

    func testManualOlderHistoryRejectsMalformedRTCWithAuthorityInAnotherConversation() async throws {
        try await assertManualOlderRTCHistoryPage(malformedField: "schema_version", authorityInOtherConversation: true)
    }

    func testManualOlderHistoryStillAcceptsOrdinaryPageWithoutRTCRecoveryGap() async throws {
        try await assertManualOlderRTCHistoryPage(malformedField: nil)
    }

    private func assertManualOlderRTCHistoryPage(
        malformedField: String?, authorityInOtherConversation: Bool = false
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-rtc-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorityChannel = "friend-1:uid-1"
        let targetChannel = authorityInOtherConversation ? "friend-2:uid-1" : authorityChannel
        var authoritativeObject = historicalRTCMessageObject(outer: "2026-08-24T00:01:45Z")
        authoritativeObject["message_id"] = "m100"
        authoritativeObject["channel_seq"] = 100
        var authoritativePayload = try XCTUnwrap(authoritativeObject["payload"] as? [String: Any])
        authoritativePayload["call_id"] = "callA"
        authoritativeObject["payload"] = authoritativePayload
        var olderObject = authoritativeObject
        olderObject["message_id"] = "m99"
        olderObject["channel_seq"] = 99
        olderObject["channel_id"] = targetChannel
        if let malformedField {
            var malformedPayload = authoritativePayload
            if malformedField == "schema_version" {
                malformedPayload[malformedField] = 2
            } else {
                malformedPayload[malformedField] = "2026-08-23T23:58:00Z"
            }
            olderObject["payload"] = malformedPayload
        } else {
            olderObject["content_type"] = "text"
            olderObject["payload"] = ["text": "普通旧消息"]
        }
        let pageData = try JSONSerialization.data(withJSONObject: [
            "ok": true, "data": ["items": [olderObject], "has_more_before": true, "total": 1]
        ])
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: pageData, isHTTPResponse: true, statusCode: 200)
        ])
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let syncEngine = DefaultSyncEngine()
        _ = syncEngine.beginRemoteSnapshotRefresh()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messagePersistence: persistence,
            remoteSyncEngine: syncEngine, apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        let authoritativeRemote = try JSONDecoder().decode(
            RemoteMessage.self, from: JSONSerialization.data(withJSONObject: authoritativeObject)
        )
        let authoritativeMessage = state.debugChatMessageForTesting(authoritativeRemote)
        XCTAssertEqual(authoritativeMessage.rtcCallRecord?.callID, "callA")
        let originalAuthority = try XCTUnwrap(RTCCallRecordMessageDeduplicator.authority(for: authoritativeMessage))
        var target = makeConversation(id: targetChannel, unread: 0, lastMsgSeq: 100, lastReadSeq: 98)
        target.messages = [authorityInOtherConversation
            ? makeMessage(id: "target-m100", seq: 100, text: "目标会话原消息")
            : authoritativeMessage]
        target.messageCoveredThroughSeq = 100
        target.messageCoverageRequiresRecovery = false
        var initial = [target]
        if authorityInOtherConversation {
            var owner = makeConversation(id: authorityChannel, unread: 0, lastMsgSeq: 100, lastReadSeq: 100)
            owner.messages = [authoritativeMessage]
            owner.messageCoveredThroughSeq = 100
            initial.append(owner)
        }
        state.conversationStore.conversations = initial

        XCTAssertTrue(state.loadOlderMessagesIfAvailable(targetChannel))
        for _ in 0..<200 {
            if !state.conversationStore.isHistoryLoading(conversationID: targetChannel) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(state.conversationStore.isHistoryLoading(conversationID: targetChannel))
        let syncRequest = try XCTUnwrap(transport.requests().first { $0.url?.path == "/api/im/sync" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(syncRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["before_seq"] as? Int, 100)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["channel_id"] as? String, targetChannel)
        XCTAssertEqual(body["channel_type"] as? String, "direct")
        let result = try XCTUnwrap(state.conversations.first { $0.id == targetChannel })
        let retainedOwner = try XCTUnwrap(state.conversations.first { $0.id == authorityChannel })
        let retained = try XCTUnwrap(retainedOwner.messages.first { $0.id == "m100" })
        XCTAssertEqual(RTCCallRecordMessageDeduplicator.authority(for: retained), originalAuthority)
        XCTAssertEqual(result.unread, 0, "Manual history is not an incoming realtime unread event")
        XCTAssertEqual(result.lastMsgSeq, 100)
        if malformedField != nil {
            XCTAssertEqual(result.messages.map(\.id), target.messages.map(\.id))
            XCTAssertFalse(result.messages.contains { $0.id == "m99" }, "Do not retain a malformed RTC fallback row")
            XCTAssertEqual(result.messageCoveredThroughSeq, 98)
            XCTAssertTrue(result.messageCoverageRequiresRecovery)
            XCTAssertEqual(state.conversationStore.latestReadableSequence(in: result), 98)
        } else {
            XCTAssertEqual(result.messages.map(\.id), ["m99", "m100"])
            XCTAssertEqual(result.messages.first?.text, "普通旧消息")
            XCTAssertEqual(result.messageCoveredThroughSeq, 100)
            XCTAssertFalse(result.messageCoverageRequiresRecovery)
            XCTAssertEqual(state.conversationStore.latestReadableSequence(in: result), 100)
        }
        if authorityInOtherConversation {
            XCTAssertEqual(retainedOwner.messageCoveredThroughSeq, 100)
            XCTAssertFalse(retainedOwner.messageCoverageRequiresRecovery)
        }
    }

    func testHighSensitivityMediaPolicyDecodesToOfflineDeny() throws {
        let nested = try JSONDecoder().decode(
            RemoteTenantClientPolicy.self,
            from: Data(#"{"media_cache":{"offline_policy":"high_sensitivity"}}"#.utf8)
        )
        XCTAssertTrue(nested.mediaOfflinePolicyPresent)
        XCTAssertEqual(nested.mediaOfflinePolicy, "high_sensitivity")
        XCTAssertEqual(AppState.mediaOfflinePolicy(for: nested), .deny)

        let defaultPolicy = try JSONDecoder().decode(
            RemoteTenantClientPolicy.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertFalse(defaultPolicy.mediaOfflinePolicyPresent)
        XCTAssertEqual(AppState.mediaOfflinePolicy(for: defaultPolicy), .bounded)
    }

    func testStickerStoreCachesByScopeAndMovesWithoutPersistingSignedURLs() throws {
        let suiteName = "BlueStoneIMTests.stickers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = StickerLibraryItem(
            id: "us-1",
            stickerID: "st-1",
            fileID: "file-1",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 96,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-1",
            version: "v1",
            thumbnailURL: "https://cdn.example.test/thumb.gif?token=secret",
            variants: [
                StickerAssetVariant(
                    kind: "thumb",
                    fileID: "thumb-1",
                    mimeType: "image/png",
                    sizeBytes: 256,
                    width: 64,
                    height: 64,
                    durationMS: nil,
                    frameCount: nil,
                    thumbnailURL: "/api/tenant/files/thumb-1/thumbnail",
                    cacheKey: "thumb-cache"
                )
            ],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )
        let second = StickerLibraryItem(
            id: "us-2",
            stickerID: "st-2",
            fileID: "file-2",
            packID: "",
            source: .mine,
            status: "queued",
            processingStatus: "processing",
            sort: 2,
            mimeType: "image/gif",
            sizeBytes: 2048,
            width: 128,
            height: 128,
            durationMS: 700,
            frameCount: 9,
            cacheKey: "cache-2",
            version: "v2",
            thumbnailURL: "/api/tenant/files/file-2/thumbnail",
            variants: [],
            createdAt: "2026-06-26T01:01:00Z",
            updatedAt: "2026-06-26T01:01:00Z"
        )
        let store = StickerStore(defaults: defaults)

        store.replaceMyStickers([second, first], scope: "tenant-a|uid-a")
        XCTAssertEqual(store.myStickers.map(\.id), ["us-1", "us-2"])
        XCTAssertTrue(store.myStickers[1].isProcessing)
        XCTAssertEqual(store.moveUserSticker(id: "us-2", direction: -1, scope: "tenant-a|uid-a"), ["us-2", "us-1"])

        let reloadedSameScope = StickerStore(defaults: defaults)
        reloadedSameScope.activate(scope: "tenant-a|uid-a")
        XCTAssertEqual(reloadedSameScope.myStickers.map(\.id), ["us-2", "us-1"])
        XCTAssertEqual(reloadedSameScope.myStickers.first(where: { $0.id == "us-1" })?.thumbnailURL, "")
        XCTAssertEqual(reloadedSameScope.myStickers.first(where: { $0.id == "us-1" })?.variants.first?.thumbnailURL, "/api/tenant/files/thumb-1/thumbnail")

        let reloadedOtherScope = StickerStore(defaults: defaults)
        reloadedOtherScope.activate(scope: "tenant-b|uid-b")
        XCTAssertTrue(reloadedOtherScope.myStickers.isEmpty)
    }

    func testStickerThumbnailURLDoesNotExposeTenantFileEndpointToImageView() {
        let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
        let endpointOnly = StickerLibraryItem(
            id: "us-endpoint",
            stickerID: "st-endpoint",
            fileID: "file-endpoint",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 128,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-endpoint",
            version: "v1",
            thumbnailURL: "/api/tenant/files/file-endpoint/thumbnail",
            variants: [
                StickerAssetVariant(
                    kind: "original",
                    fileID: "file-endpoint",
                    mimeType: "image/gif",
                    assetURL: "/api/tenant/files/file-endpoint/presign-download",
                    sizeBytes: 1024,
                    width: 128,
                    height: 128,
                    durationMS: 600,
                    frameCount: 8,
                    thumbnailURL: "/api/tenant/files/file-endpoint/thumbnail",
                    cacheKey: "cache-endpoint"
                )
            ],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )
        let signed = StickerLibraryItem(
            id: "us-signed",
            stickerID: "st-signed",
            fileID: "file-signed",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 128,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-signed",
            version: "v1",
            thumbnailURL: "https://cdn.example.test/sticker.gif?signature=safe-for-render",
            variants: [],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )

        XCTAssertEqual(state.stickerThumbnailURL(for: endpointOnly), "")
        XCTAssertEqual(state.stickerThumbnailURL(for: signed), "https://cdn.example.test/sticker.gif?signature=safe-for-render")
    }

    func testPrepareStickerPanelHydratesCachedEndpointOnlyStickersBeforeManifestRefresh() async throws {
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-\(UUID().uuidString)",
            tenantID: "tenant-\(UUID().uuidString)",
            imUID: "uid-\(UUID().uuidString)",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let scope = [context.tenantID, context.imUID, context.accountID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        let cachedStore = StickerStore()
        cachedStore.replaceMyStickers([
            StickerLibraryItem(
                id: "us-cached",
                stickerID: "st-cached",
                fileID: "file-cached",
                packID: "",
                source: .mine,
                status: "active",
                processingStatus: "active",
                sort: 1,
                mimeType: "image/gif",
                sizeBytes: 4096,
                width: 128,
                height: 128,
                durationMS: 600,
                frameCount: 8,
                cacheKey: "cache-cached",
                version: "v1",
                thumbnailURL: "/api/tenant/files/file-cached/thumbnail",
                variants: [
                    StickerAssetVariant(
                        kind: "original",
                        fileID: "file-cached",
                        mimeType: "image/gif",
                        assetURL: "/api/tenant/files/file-cached/presign-download",
                        sizeBytes: 4096,
                        width: 128,
                        height: 128,
                        durationMS: 600,
                        frameCount: 8,
                        thumbnailURL: "/api/tenant/files/file-cached/thumbnail",
                        cacheKey: "cache-cached"
                    )
                ],
                createdAt: "2026-06-26T01:00:00Z",
                updatedAt: "2026-06-26T01:00:00Z"
            )
        ], scope: scope)

        let transport = StickerPanelHydrationHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context)

        await state.prepareStickerExpressionPanel(force: true)

        let hydrated = try XCTUnwrap(state.myStickers.first(where: { $0.id == "us-cached" }))
        XCTAssertEqual(state.stickerThumbnailURL(for: hydrated), "https://cdn.example.test/file-cached-thumb.gif?sig=unit")
        XCTAssertTrue(transport.paths().contains("/api/tenant/files/file-cached"))
        XCTAssertTrue(transport.paths().contains { $0.hasPrefix("/api/tenant/user-stickers") })
    }

    func testStickerStoreLocalUploadTileTracksProgressAndStaysOutOfCache() throws {
        let suiteName = "BlueStoneIMTests.stickerUploadTile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = StickerStore(defaults: defaults)
        let scope = "tenant-a|uid-a"
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        store.beginLocalUpload(
            id: uploadID,
            name: "wave.png",
            mimeType: "image/png",
            sizeBytes: imageData.count,
            data: imageData,
            conversationID: "conversation-1",
            scope: scope
        )

        XCTAssertEqual(store.myStickers.map(\.id), [uploadID])
        XCTAssertTrue(store.myStickers[0].isLocalUploadPlaceholder)
        XCTAssertEqual(store.myStickers[0].uploadTileTitle, "2%")
        XCTAssertEqual(store.myStickers[0].uploadSubtitle, "上传中")
        XCTAssertTrue(store.isUploading)

        store.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.36, scope: scope)
        XCTAssertEqual(store.myStickers[0].uploadTileTitle, "36%")
        XCTAssertEqual(store.localUploadDraft(id: uploadID)?.conversationID, "conversation-1")

        store.failLocalUpload(id: uploadID, scope: scope)
        XCTAssertFalse(store.isUploading)
        XCTAssertTrue(store.myStickers[0].isFailed)
        XCTAssertEqual(store.myStickers[0].statusTitle, "失败")
        XCTAssertNotNil(store.localUploadDraft(id: uploadID))

        let reloaded = StickerStore(defaults: defaults)
        reloaded.activate(scope: scope)
        XCTAssertTrue(reloaded.myStickers.isEmpty)

        store.removeLocalUpload(id: uploadID, scope: scope)
        XCTAssertTrue(store.myStickers.isEmpty)
        XCTAssertNil(store.localUploadDraft(id: uploadID))
    }

    func testConversationListTimeOnlyAfterMidnightFallsBackToYesterday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))

        let timestamp = try XCTUnwrap(conversationListDisplayTimestamp("03:44", now: now, calendar: calendar))

        XCTAssertEqual(timestamp, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testConversationListDisplayTimeUsesYesterdayForStoredTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))
        var conversation = makeConversation(id: "conversation_time_test", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.time = "03:44"
        conversation.sortTimestamp = yesterday.timeIntervalSince1970

        XCTAssertEqual(conversationListDisplayTime(for: conversation, now: now, calendar: calendar), "昨天 03:44")
    }

    func testConversationListMutableActionsExcludeOnlyProtectedSystemRows() {
        let system = makeConversation(
            id: "system_notification",
            kind: .system,
            unread: 2,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        var direct = makeConversation(
            id: "direct-system-topic",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        direct.title = "系统升级讨论"
        var group = makeConversation(
            id: "group-system-topic",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        group.title = "系统维护群"

        XCTAssertFalse(conversationListSupportsMutableActions(system))
        XCTAssertTrue(conversationListSupportsMutableActions(direct))
        XCTAssertTrue(conversationListSupportsMutableActions(group))
    }

    func testAppStateRejectsProtectedSystemConversationMutableActions() {
        let transport = SystemInboxReadHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let system = makeConversation(
            id: "system_notification",
            kind: .system,
            unread: 2,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        state.conversationStore.conversations = [system]

        state.togglePinned(system.id)
        state.toggleMuted(system.id)
        state.deleteConversation(system.id)

        XCTAssertEqual(state.conversations.map(\.id), [system.id])
        XCTAssertFalse(state.conversations[0].isPinned)
        XCTAssertFalse(state.conversations[0].isMuted)
        XCTAssertTrue(transport.requestPaths().isEmpty)
    }

    func testConversationListNormalizesFutureTimeOnlySortTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let staleToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 3, minute: 44)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))

        let timestamp = conversationListNormalizedTimestamp(staleToday.timeIntervalSince1970, now: now, calendar: calendar)

        XCTAssertEqual(timestamp, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testConversationListActivityDecisionScrollsOrHintsOnlyForRealOrderChanges() {
        // 近顶时列表顶部锚定,重排结果天然可见;程序化回顶会打断真机拖拽手势,
        // 因此近顶的排序变化不再触发任何动作。
        XCTAssertEqual(
            conversationListActivityDecision(
                previousOrder: ["old", "new"],
                nextOrder: ["new", "old"],
                isNearTop: true
            ),
            .none
        )
        XCTAssertEqual(
            conversationListActivityDecision(
                previousOrder: ["old", "new"],
                nextOrder: ["new", "old"],
                isNearTop: false
            ),
            .showHint
        )
        XCTAssertEqual(
            conversationListActivityDecision(
                previousOrder: [],
                nextOrder: ["new"],
                isNearTop: false
            ),
            .none
        )
        XCTAssertEqual(
            conversationListActivityDecision(
                previousOrder: ["new", "old"],
                nextOrder: ["new", "old"],
                isNearTop: false
            ),
            .none
        )
    }

    func testConversationUnreadStateKeepsReactionUnreadAfterLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 1,
            remoteUnreadReactionCount: 1,
            remoteHasReactionUnread: true,
            locallyReadThrough: true
        )

        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertTrue(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 1)
        XCTAssertFalse(state.hasUnreadMessages)
    }

    func testConversationUnreadStateClearsOnlyNormalUnreadAfterLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 3,
            remoteUnreadReactionCount: 0,
            remoteHasReactionUnread: false,
            locallyReadThrough: true
        )

        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertFalse(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 0)
        XCTAssertFalse(state.hasUnreadMessages)
    }

    func testConversationUnreadStatePreservesMixedUnreadWithoutLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 5,
            remoteUnreadReactionCount: 2,
            remoteHasReactionUnread: true,
            locallyReadThrough: false
        )

        XCTAssertEqual(state.unreadCount, 5)
        XCTAssertTrue(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 2)
        XCTAssertTrue(state.hasUnreadMessages)
    }

    func testChatInitialScrollAnchorUsesBottomForUnreadEntry() throws {
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, isOutgoing: true, text: "last read full content"),
            makeMessage(id: "m43", seq: 43)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 42,
            firstUnreadMessageID: "m43",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialLatestWindowWaitIgnoresUnreadOnlyRefresh() {
        XCTAssertFalse(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: false,
            canReuseConfirmedBottom: false
        ))
        XCTAssertTrue(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: false
        ))
        XCTAssertFalse(chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: true
        ))
    }

    func testChatInitialEntrySyncPolicyDoesNotForceRemoteHistoryForUnreadOnlyEntry() {
        let policy = chatInitialEntrySyncPolicy(
            hasCachedMessages: true,
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: false,
            canReuseConfirmedBottom: false
        )

        XCTAssertEqual(policy, ChatInitialEntrySyncPolicy(
            forceRemoteHistory: false,
            silent: true,
            showLoadingIndicator: false,
            shouldWarmRefreshAfterInitialRender: true
        ))
    }

    func testChatInitialEntrySyncPolicyForcesRemoteHistoryWhenLatestWindowIsMissing() {
        let policy = chatInitialEntrySyncPolicy(
            hasCachedMessages: true,
            needsUnreadWindowRefresh: true,
            needsLatestWindowRefresh: true,
            canReuseConfirmedBottom: false
        )

        XCTAssertEqual(policy, ChatInitialEntrySyncPolicy(
            forceRemoteHistory: true,
            silent: false,
            showLoadingIndicator: true,
            shouldWarmRefreshAfterInitialRender: false
        ))
    }

    func testChatInitialScrollAnchorUsesBottomForUnreadEntryBeforeOldReadStatus() throws {
        var oldReadStatus = makeMessage(id: "m10", seq: 10, status: .read, isOutgoing: true, text: "old read receipt")
        oldReadStatus.readCount = 2
        let messages = [
            oldReadStatus,
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, text: "last read before unread"),
            makeMessage(id: "m43", seq: 43, text: "new unread")
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 42,
            firstUnreadMessageID: "m43",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatUnreadReminderDoesNotClearFromInitialVisibleProgress() {
        XCTAssertFalse(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: false,
            isAtBottom: false,
            didScrollTowardUnreadMessages: false
        ))
        XCTAssertTrue(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: false,
            isAtBottom: false,
            didScrollTowardUnreadMessages: true
        ))
        XCTAssertTrue(chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: true,
            isAtBottom: true,
            didScrollTowardUnreadMessages: false
        ))
    }

    func testAutomaticReadSyncFailureDoesNotImmediatelyToast() {
        XCTAssertNil(chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: true))
        XCTAssertEqual(
            chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: false),
            "已读状态同步失败，请稍后重试"
        )
    }

    func testReadObservationAdvancesWhenBottomBooleanStaysUnchanged() {
        let visibleRow = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 500, width: 300, height: 80), epoch: 4)
        let first = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600,
            renderedReadToken: "chat:20", renderedReadSeq: 20, readVisibilityEpoch: 4)
        let next = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -450, contentMaxY: 600,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        XCTAssertEqual(chatScrollVisibility(metrics: first), chatScrollVisibility(metrics: next))
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(chatVisibleIncomingReadSequence(metrics: next, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true), 21)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: next, row: .empty, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        let offscreen = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 650, width: 300, height: 80), epoch: 4)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: next, row: offscreen, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        // The Store may publish 21 before the layout containing 20 is replaced.
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: first, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
    }

    func testReadObservationRejectsOffscreenBackgroundAndStaleScopeOrEpoch() {
        let visibleRow = ChatIncomingRowGeometry(token: "chat:21", frame: CGRect(x: 0, y: 500, width: 300, height: 80), epoch: 4)
        var metrics = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -450, contentMaxY: 650,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        // Within the scrolling tolerance is insufficient to mark the bottom read.
        XCTAssertTrue(chatScrollVisibility(metrics: metrics).isAtBottom)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: true))
        metrics = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -500, contentMaxY: 600,
            renderedReadToken: "chat:21", renderedReadSeq: 21, readVisibilityEpoch: 4)
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: false, scopeMatches: true))
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 4, isActive: true, scopeMatches: false))
        XCTAssertNil(chatVisibleIncomingReadSequence(metrics: metrics, row: visibleRow, expectedToken: "chat:21",
            epoch: 5, isActive: true, scopeMatches: true))
    }

    func testLayoutCallbacksCoalesceBurstsAndInvalidateOnDeparture() throws {
        var callbacks = ChatLayoutCallbackCoalescer()
        let first = try XCTUnwrap(callbacks.schedule())
        for _ in 0..<1_000 { XCTAssertNil(callbacks.schedule()) }
        XCTAssertTrue(callbacks.consume(first))
        XCTAssertFalse(callbacks.consume(first))
        let obsolete = try XCTUnwrap(callbacks.schedule())
        callbacks.cancel()
        let current = try XCTUnwrap(callbacks.schedule())
        XCTAssertFalse(callbacks.consume(obsolete))
        XCTAssertTrue(callbacks.consume(current))
        // Geometry caused by the applied state can schedule one subsequent pass.
        XCTAssertNotNil(callbacks.schedule())
        XCTAssertNil(callbacks.schedule())
    }

    func testIncomingBottomFollowRetainsPreAppendBottomAcrossBurstAndMediaLayout() {
        var follow = ChatIncomingBottomFollowState()
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600)
        let tallAppend = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 1600)
        follow.recordAppend(metrics: bottom, generation: 7, eligible: true)
        XCTAssertEqual(follow.decision(generation: 7), true)
        XCTAssertFalse(chatScrollVisibility(metrics: tallAppend).isAtBottom)
        follow.recordAppend(metrics: tallAppend, generation: 7, eligible: true)
        XCTAssertEqual(follow.decision(generation: 7), true)
        // Layout is not a user action and must not revoke the original decision.
        XCTAssertEqual(follow.decision(generation: 7), true)
    }

    func testIncomingBottomFollowPreservesHistoryUntilActuallyBackAtBottom() {
        var follow = ChatIncomingBottomFollowState()
        let history = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -100, contentMaxY: 1400)
        follow.recordAppend(metrics: history, generation: 3, eligible: true)
        XCTAssertEqual(follow.decision(generation: 3), false)
        follow.recordAppend(metrics: history, generation: 3, eligible: true)
        XCTAssertEqual(follow.decision(generation: 3), false)
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -900, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: 4, eligible: true)
        XCTAssertEqual(follow.decision(generation: 4), true)
    }

    func testIncomingBottomFollowUserDragInvalidatesQueuedBurstAndMediaWork() {
        var follow = ChatIncomingBottomFollowState()
        let control = ChatTranscriptScrollControl()
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -400, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: control.generation, eligible: true)
        XCTAssertEqual(follow.decision(generation: control.generation), true)
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 20), now: now, suppressionInterval: 1)
        XCTAssertNil(follow.decision(generation: control.generation))
        follow.recordAppend(metrics: bottom, generation: control.generation, eligible: false)
        XCTAssertEqual(follow.decision(generation: control.generation), false)
        _ = control.finishDrag(now: now, suppressionInterval: 1)
        XCTAssertNil(follow.decision(generation: control.generation))
    }

    func testIncomingBottomFollowRejectsMissingGeometryAndResetsOnScopeOrPrepend() {
        var follow = ChatIncomingBottomFollowState()
        follow.recordAppend(metrics: .zero, generation: 1, eligible: true)
        XCTAssertEqual(follow.decision(generation: 1), false)
        let short = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: 0, contentMaxY: 300)
        follow.recordAppend(metrics: short, generation: 1, eligible: true)
        XCTAssertEqual(follow.decision(generation: 1), true)
        follow.reset()
        XCTAssertNil(follow.decision(generation: 1))
        follow.recordAppend(metrics: short, generation: 2, eligible: false)
        XCTAssertEqual(follow.decision(generation: 2), false)
    }

    func testIncomingBottomFollowHasSeparateArbiterRouteAfterManualReturn() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 1)
        let generation = arbiter.generation
        _ = arbiter.evaluate(ConversationScrollRequest(source: .userGesture, targetID: nil,
            anchor: nil, userInitiated: true, generation: generation), now: now)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .followBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .deny)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .incomingFollowBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .allow)
        arbiter.beginNormalOpen(now: now, duration: 1)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .incomingFollowBottom, targetID: "bottom",
            anchor: .bottom, userInitiated: false, generation: generation), now: now), .deny)
    }

    func testIncomingBottomFollowCorrectsViewportShrinkAfterConfirmedAppend() {
        var follow = ChatIncomingBottomFollowState()
        let confirmedBottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -800, contentMaxY: 600)
        follow.recordAppend(metrics: confirmedBottom, generation: 7, eligible: true)
        let shorterViewport = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -800, contentMaxY: 600)
        XCTAssertEqual(confirmedBottom.contentHeight, shorterViewport.contentHeight)
        XCTAssertTrue(follow.needsLayoutCorrection(from: confirmedBottom, to: shorterViewport, generation: 7))
        let corrected = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -920, contentMaxY: 480)
        XCTAssertFalse(follow.needsLayoutCorrection(from: shorterViewport, to: corrected, generation: 7))
        let lateMedia = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -920, contentMaxY: 900)
        XCTAssertTrue(follow.needsLayoutCorrection(from: corrected, to: lateMedia, generation: 7))
    }

    func testIncomingBottomFollowViewportShrinkDoesNotOverrideHistoryOrNewGesture() {
        var follow = ChatIncomingBottomFollowState()
        let history = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -100, contentMaxY: 1400)
        let shorterViewport = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -100, contentMaxY: 1400)
        follow.recordAppend(metrics: history, generation: 7, eligible: true)
        XCTAssertFalse(follow.needsLayoutCorrection(from: history, to: shorterViewport, generation: 7))
        let bottom = ChatScrollMetricsSnapshot(viewportHeight: 600, contentMinY: -900, contentMaxY: 600)
        follow.recordAppend(metrics: bottom, generation: 8, eligible: true)
        XCTAssertFalse(follow.needsLayoutCorrection(from: bottom, to: shorterViewport, generation: 9))
        follow.reset()
        XCTAssertFalse(follow.needsLayoutCorrection(from: bottom, to: shorterViewport, generation: 8))
    }

    func testViewportRealignmentDoesNotReenableOrdinaryFollowingAfterManualReturn() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 1)
        let generation = arbiter.generation
        _ = arbiter.evaluate(ConversationScrollRequest(source: .userGesture, targetID: nil,
            anchor: nil, userInitiated: true, generation: generation), now: now)
        let later = now.addingTimeInterval(10)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .viewportBottomRealignment,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .allow)
        XCTAssertTrue(arbiter.isJumpMode)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .followBottom,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .deny)
        arbiter.beginNormalOpen(now: later, duration: 1)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(source: .viewportBottomRealignment,
            targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation), now: later), .deny)
    }

    func testViewportExpansionRealignsVisibleBottomWithKeyboardSizedGap() {
        let keyboard = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -1000, contentMaxY: 480)
        let restored = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: -1000, contentMaxY: 480)
        // Both remain "visible at bottom", which previously skipped correction.
        XCTAssertEqual(chatScrollVisibility(metrics: keyboard), chatScrollVisibility(metrics: restored))
        XCTAssertTrue(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: restored))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: restored, to: restored))
        let aligned = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: -674, contentMaxY: 806)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: aligned))
    }

    func testViewportExpansionDoesNotRepositionHistoryOrUnderfilledContent() {
        let history = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -200, contentMaxY: 900)
        let restoredHistory = ChatScrollMetricsSnapshot(viewportHeight: 1000, contentMinY: -200, contentMaxY: 900)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: history, to: restoredHistory))
        let short = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: 0, contentMaxY: 400)
        let restoredShort = ChatScrollMetricsSnapshot(viewportHeight: 806, contentMinY: 0, contentMaxY: 400)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: short, to: restoredShort))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: .zero, to: restoredShort))
    }

    func testViewportExpansionIgnoresNormalSlackAndViewportShrink() {
        let keyboard = ChatScrollMetricsSnapshot(viewportHeight: 480, contentMinY: -1000, contentMaxY: 480)
        let smallGap = ChatScrollMetricsSnapshot(viewportHeight: 500, contentMinY: -1000, contentMaxY: 480)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: smallGap))
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: smallGap, to: keyboard))
        let invalid = ChatScrollMetricsSnapshot(viewportHeight: .infinity, contentMinY: -1000, contentMaxY: 480)
        XCTAssertFalse(chatNeedsBottomRealignmentAfterViewportExpansion(from: keyboard, to: invalid))
    }

    func testChatScrollVisibilityTreatsShortContentAsBottom() {
        let visibility = chatScrollVisibility(metrics: ChatScrollMetricsSnapshot(
            viewportHeight: 600,
            contentMinY: 0,
            contentMaxY: 420
        ))

        XCTAssertTrue(visibility.isAtBottom)
        XCTAssertTrue(visibility.isNearHistoryBoundary)
        XCTAssertTrue(visibility.isContentUnderfilled)
    }

    func testChatScrollVisibilityDetectsBottomWithinTolerance() {
        let visibility = chatScrollVisibility(
            metrics: ChatScrollMetricsSnapshot(
                viewportHeight: 600,
                contentMinY: -760,
                contentMaxY: 632
            ),
            bottomTolerance: 56,
            historyPrefetchDistance: 160
        )

        XCTAssertTrue(visibility.isAtBottom)
        XCTAssertFalse(visibility.isNearHistoryBoundary)
        XCTAssertFalse(visibility.isContentUnderfilled)
    }

    func testChatScrollVisibilityDetectsHistoryPrefetchBoundary() {
        let visibility = chatScrollVisibility(
            metrics: ChatScrollMetricsSnapshot(
                viewportHeight: 600,
                contentMinY: -120,
                contentMaxY: 1_480
            ),
            bottomTolerance: 56,
            historyPrefetchDistance: 160
        )

        XCTAssertFalse(visibility.isAtBottom)
        XCTAssertTrue(visibility.isNearHistoryBoundary)
        XCTAssertFalse(visibility.isContentUnderfilled)
    }

    func testReturnToBottomPolicyRequiresMeasuredHistoryDistanceAndHasNoImmediateSideEffects() {
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: false,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 0,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: true,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertTrue(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: true,
            isReadOnlySystemConversation: false
        ))
        XCTAssertFalse(chatShouldShowReturnToBottom(
            didInitialScroll: true,
            isApplyingInitialScroll: false,
            messageCount: 40,
            isAtBottom: false,
            isSearchVisible: false,
            isReadOnlySystemConversation: true
        ))

        let plan = chatReturnToBottomActionPlan(bottomAnchorID: "chat-bottom-anchor")
        XCTAssertEqual(plan.targetID, "chat-bottom-anchor")
        XCTAssertEqual(plan.source, .jumpToLatest)
        XCTAssertEqual(plan.anchor, .bottom)
        XCTAssertFalse(plan.acknowledgesReadImmediately)
        XCTAssertFalse(plan.loadsHistoryPage)
        XCTAssertFalse(plan.rebuildsTimeline)
    }

    func testTranscriptKeyboardDismissalTriggersPreserveDraftAndHaveNoChatSideEffects() {
        for trigger in ChatTranscriptKeyboardDismissalTrigger.allCases {
            let plan = chatTranscriptKeyboardDismissalPlan(trigger: trigger)
            XCTAssertTrue(plan.dismissesKeyboard)
            XCTAssertTrue(plan.preservesDraft)
            XCTAssertFalse(plan.sendsMessage)
            XCTAssertFalse(plan.acknowledgesRead)
            XCTAssertFalse(plan.loadsHistoryPage)
            XCTAssertFalse(plan.rebuildsTimeline)
            XCTAssertFalse(plan.requestsScrollTarget)
        }
    }

    func testChatMessageTopMeasurementStoreDoesNotPublishGeometryWrites() {
        let store = ChatMessageTopMeasurementStore()
        var viewInvalidationCount = 0
        let cancellable = store.objectWillChange.sink {
            viewInvalidationCount += 1
        }

        store.replace(with: ["message-1": 42, "message-2": -18], isEnabled: true)

        XCTAssertEqual(store.values, ["message-1": 42, "message-2": -18])
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: ["message-3": 7], isEnabled: false)

        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: ["message-4": 11], isEnabled: true)
        store.removeAll()

        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(viewInvalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testTranscriptDragOneHundredSameDirectionFramesHaveOneSemanticActionAndNoPublications() {
        let control = ChatTranscriptScrollControl()
        var publications = 0
        var semanticActions = 0
        var historyLogActions = 0
        let observation = control.objectWillChange.sink { publications += 1 }
        let now = Date(timeIntervalSince1970: 100)

        for frame in 1...100 {
            // This is the same gate used before ChatView's state, read-gate
            // scans and history diagnostics, not a separate debounce fixture.
            if let transition = control.updateDrag(
                translation: CGSize(width: 0, height: CGFloat(frame * 8)),
                now: now.addingTimeInterval(Double(frame) / 10),
                suppressionInterval: 1.6
            ) {
                semanticActions += 1
                if transition.direction == .history { historyLogActions += 1 }
                XCTAssertTrue(transition.isStart)
            }
        }

        XCTAssertEqual(semanticActions, 1)
        XCTAssertEqual(historyLogActions, 1)
        XCTAssertEqual(control.generation, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(30)))
        withExtendedLifetime(observation) {}
    }

    func testTranscriptLatestDragRepeatedFramesStayBoundedAndHistoryReversalSurvivesEnd() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        var transitions = 0
        for frame in 1...100 {
            if control.updateDrag(
                translation: CGSize(width: 0, height: -CGFloat(frame * 8)),
                now: now, suppressionInterval: 1.6
            ) != nil { transitions += 1 }
        }
        XCTAssertEqual(transitions, 1)
        XCTAssertEqual(control.generation, 1)
        XCTAssertFalse(control.isSuppressed(now: now))
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: -790), now: now, suppressionInterval: 1.6
        )?.direction, .history)
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: -795), now: now, suppressionInterval: 1.6
        )?.direction, .latest)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(20)))
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(20), suppressionInterval: 1.6), .latest)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(21.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(21.6)))
    }

    func testTranscriptDragReversesBeforeCrossingItsOriginAndCancelsOldBottomWork() throws {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        let queuedBeforeDrag = control.nextGeneration()
        let first = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 100), now: now, suppressionInterval: 1.6
        ))
        XCTAssertTrue(first.isStart)
        XCTAssertEqual(first.direction, .history)
        XCTAssertNotEqual(control.generation, queuedBeforeDrag)
        let queuedBeforeReversal = control.generation

        let reverse = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 90), now: now.addingTimeInterval(1), suppressionInterval: 1.6
        ))
        XCTAssertFalse(reverse.isStart)
        XCTAssertEqual(reverse.direction, .latest)
        XCTAssertNotEqual(control.generation, queuedBeforeReversal)
        XCTAssertNil(control.updateDrag(
            translation: CGSize(width: 0, height: 80), now: now.addingTimeInterval(2), suppressionInterval: 1.6
        ))
        XCTAssertEqual(control.updateDrag(
            translation: CGSize(width: 0, height: 85), now: now.addingTimeInterval(3), suppressionInterval: 1.6
        )?.direction, .history)
    }

    func testTranscriptLongDragHoldsSuppressionThroughBottomGeometryAndAfterEnd() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        control.clearSuppression() // The existing bottom-visibility callback.
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(30)))
        let duringDragGeneration = control.generation
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(30), suppressionInterval: 1.6), .history)
        XCTAssertNotEqual(control.generation, duringDragGeneration)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(31.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(31.6)))
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(35), suppressionInterval: 1.6))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(35)))
    }

    func testTranscriptHorizontalFinishAndScopeResetDoNotLeakGestureOrReuseGeneration() {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 80, height: 8), now: now, suppressionInterval: 1.6))
        XCTAssertNil(control.direction)
        XCTAssertEqual(control.generation, 0)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 20), now: now, suppressionInterval: 1.6)
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 100, height: 20), now: now, suppressionInterval: 1.6))
        XCTAssertEqual(control.finishDrag(now: now, suppressionInterval: 1.6), .history)
        let oldGeneration = control.generation
        control.reset()
        XCTAssertGreaterThan(control.generation, oldGeneration)
        XCTAssertNil(control.direction)
        XCTAssertFalse(control.isSuppressed(now: now))
        let nextDrag = control.updateDrag(translation: CGSize(width: 0, height: -8), now: now, suppressionInterval: 1.6)
        XCTAssertEqual(nextDrag, ChatTranscriptScrollControl.Transition(isStart: true, direction: .latest))
        XCTAssertNil(control.updateDrag(translation: CGSize(width: 0, height: -8), now: now, suppressionInterval: 1.6))
    }

    func testTranscriptSuppressionPreservesHistoryAnchorAndExplicitReturnToBottom() {
        let control = ChatTranscriptScrollControl()
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 3)
        let generation = arbiter.generation
        func request(_ source: ConversationScrollRequestSource, userInitiated: Bool = false) -> ConversationScrollRequest {
            ConversationScrollRequest(source: source, targetID: "anchor", anchor: .top, userInitiated: userInitiated, generation: generation)
        }
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        XCTAssertEqual(arbiter.evaluate(request(.userGesture, userInitiated: true), now: now), .allowAndEndWindow)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(20)))
        XCTAssertEqual(arbiter.evaluate(request(.historyPrependCompensation), now: now), .allow)
        XCTAssertEqual(arbiter.evaluate(request(.followBottom), now: now), .deny)
        let returnPlan = chatReturnToBottomActionPlan(bottomAnchorID: "bottom")
        control.suppress(now: now, interval: 1.6)
        XCTAssertEqual(arbiter.evaluate(request(returnPlan.source, userInitiated: true), now: now), .allowAndEndWindow)
        XCTAssertFalse(arbiter.isJumpMode)
        XCTAssertFalse(returnPlan.rebuildsTimeline)
        XCTAssertFalse(returnPlan.loadsHistoryPage)
    }

    func testTranscriptCancellationExpiresAndSameScopeHistoryDragStartsFresh() throws {
        let control = ChatTranscriptScrollControl()
        let now = Date(timeIntervalSince1970: 100)
        _ = control.updateDrag(translation: CGSize(width: 0, height: 80), now: now, suppressionInterval: 1.6)
        let queuedBeforeCancel = control.generation
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(600)))

        // The GestureState reset callback uses the same finish as normal end.
        XCTAssertEqual(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6), .history)
        XCTAssertNil(control.direction)
        XCTAssertNotEqual(control.generation, queuedBeforeCancel)
        XCTAssertTrue(control.isSuppressed(now: now.addingTimeInterval(601.5)))
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(602)))

        // No scope reset: the same translation must start a fresh drag, not be
        // suppressed as the previous gesture's same-direction/zero-delta frame.
        let resumed = try XCTUnwrap(control.updateDrag(
            translation: CGSize(width: 0, height: 80),
            now: now.addingTimeInterval(603), suppressionInterval: 1.6
        ))
        XCTAssertEqual(resumed, .init(isStart: true, direction: .history))
    }

    func testTranscriptNormalEndAndCancelFinishAreIdempotentInEitherOrder() {
        for firstCallback in ["onEnded", "gestureStateReset"] {
            let control = ChatTranscriptScrollControl()
            let now = Date(timeIntervalSince1970: 100)
            _ = control.updateDrag(translation: CGSize(width: 0, height: 80), now: now, suppressionInterval: 1.6)
            _ = control.updateDrag(translation: CGSize(width: 0, height: 70), now: now, suppressionInterval: 1.6)
            XCTAssertEqual(control.finishDrag(now: now, suppressionInterval: 1.6), .latest, firstCallback)
            let finishedGeneration = control.generation
            let finishedDeadline = control.suppressedUntil
            XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6), firstCallback)
            XCTAssertEqual(control.generation, finishedGeneration, firstCallback)
            XCTAssertEqual(control.suppressedUntil, finishedDeadline, firstCallback)
            XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(600)), firstCallback)
        }
    }

    func testTranscriptSceneAndPageDepartureFinishWithoutPublishingOrLosingAnchorAuthority() {
        let control = ChatTranscriptScrollControl()
        var publications = 0
        let observer = control.objectWillChange.sink { publications += 1 }
        let now = Date(timeIntervalSince1970: 100)
        var arbiter = ConversationScrollArbiter()
        arbiter.beginNormalOpen(now: now, duration: 3)
        let anchorGeneration = arbiter.generation
        _ = control.updateDrag(translation: CGSize(width: 0, height: 8), now: now, suppressionInterval: 1.6)
        _ = control.finishDrag(now: now, suppressionInterval: 1.6) // scene non-active
        let finishedGeneration = control.generation
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(1), suppressionInterval: 1.6)) // disappear
        XCTAssertNil(control.finishDrag(now: now.addingTimeInterval(600), suppressionInterval: 1.6)) // same-scope appear
        XCTAssertEqual(control.generation, finishedGeneration)
        XCTAssertFalse(control.isSuppressed(now: now.addingTimeInterval(600)))
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(
            source: .historyPrependCompensation, targetID: "history-anchor", anchor: .top,
            userInitiated: false, generation: anchorGeneration
        ), now: now), .allow)
        XCTAssertEqual(arbiter.evaluate(ConversationScrollRequest(
            source: .jumpToLatest, targetID: "bottom", anchor: .bottom,
            userInitiated: true, generation: anchorGeneration
        ), now: now), .allowAndEndWindow)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observer) {}
    }

    func testChatScrollMetricsMeasurementStoreDoesNotPublishGeometryWrites() {
        let store = ChatScrollMetricsMeasurementStore()
        var viewInvalidationCount = 0
        let cancellable = store.objectWillChange.sink {
            viewInvalidationCount += 1
        }
        let first = ChatScrollMetricsSnapshot(
            viewportHeight: 720,
            contentMinY: -120,
            contentMaxY: 1_680
        )
        let second = ChatScrollMetricsSnapshot(
            viewportHeight: 720,
            contentMinY: -360,
            contentMaxY: 1_440
        )

        store.replace(with: first)
        store.replace(with: second)

        XCTAssertEqual(store.metrics, second)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.replace(with: .zero)

        XCTAssertEqual(store.metrics, second)
        XCTAssertEqual(viewInvalidationCount, 0)

        store.removeAll()

        XCTAssertEqual(store.metrics, .zero)
        XCTAssertEqual(viewInvalidationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testChatOlderHistoryLoadAllowsPassiveScrollMetricsAtTop() {
        let visibility = ChatScrollVisibility(isAtBottom: false, isNearHistoryBoundary: true)

        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
    }

    func testChatOlderHistoryLoadAutofillsWhenShortContentIsBothTopAndBottom() {
        let visibility = ChatScrollVisibility(
            isAtBottom: true,
            isNearHistoryBoundary: true,
            isContentUnderfilled: true
        )

        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
        XCTAssertTrue(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: true,
            isUserBrowsingHistory: true,
            visibility: visibility
        ))
    }

    func testChatOlderHistoryLoadDoesNotAutofillAtBottomWhenContentCanScroll() {
        let visibility = ChatScrollVisibility(
            isAtBottom: true,
            isNearHistoryBoundary: true,
            isContentUnderfilled: false
        )

        XCTAssertFalse(chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: false,
            isUserBrowsingHistory: false,
            visibility: visibility
        ))
    }

    func testChatInitialScrollAnchorUsesBottomWhenLatestReadMessageIsVisible() throws {
        var latestReadMessage = makeMessage(id: "m42", seq: 42, status: .read, isOutgoing: true, text: "last read full content")
        latestReadMessage.readCount = 2
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            latestReadMessage
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenNewerMessagesFollowReadStatus() throws {
        var readMessage = makeMessage(id: "m40", seq: 40, status: .read, isOutgoing: true, text: "last displayed read message")
        readMessage.readCount = 3
        let middleIncoming = makeMessage(id: "m41", seq: 41, text: "newer incoming")
        let latestIncoming = makeMessage(id: "m42", seq: 42)
        let messages = [readMessage, middleIncoming, latestIncoming]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenReadCursorIsOutsideLatestWindow() throws {
        let latestMessages = [
            makeMessage(id: "m50", seq: 50),
            makeMessage(id: "m51", seq: 51)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: latestMessages,
            unreadCount: 0,
            lastReadSeq: 42,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenFirstUnreadLacksRemoteID() throws {
        let messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, isOutgoing: true),
            makeMessage(id: "m3", seq: 3),
            makeMessage(id: "m4", seq: 4)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 2,
            lastReadSeq: 0,
            firstUnreadMessageID: "",
            firstUnreadSeq: 3,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenUnreadSeqIsJustOutsideWindow() throws {
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, isOutgoing: true)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 0,
            firstUnreadMessageID: "",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatCanReuseConfirmedBottomForSameReadWindow() {
        XCTAssertTrue(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertTrue(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 45
        ))
    }

    func testChatCannotReuseConfirmedBottomForUnreadOrNewerWindow() {
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 1,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 43,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 0,
            isLatestMessageWindowLoaded: true,
            rememberedConfirmedSeq: 42
        ))
        XCTAssertFalse(chatCanReuseConfirmedBottom(
            unreadCount: 0,
            latestBottomTargetSeq: 42,
            isLatestMessageWindowLoaded: false,
            rememberedConfirmedSeq: 42
        ))
    }

    func testChatAutomaticBottomScrollStopsAfterUserLeavesBottom() {
        XCTAssertTrue(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: false,
            isAtBottom: false
        ))
        XCTAssertFalse(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: true,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: true,
            isAtBottom: false
        ))
        XCTAssertFalse(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: true,
            didUserInteractWithMessageScroll: true,
            isAtBottom: false
        ))
        XCTAssertTrue(chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: false,
            isLoadingConversationHistory: false,
            isAutomaticBottomScrollSuppressed: false,
            didUserInteractWithMessageScroll: true,
            isAtBottom: true
        ))
    }

    func testChatLatestBottomConfirmationUsesNextMainQueueTick() {
        XCTAssertEqual(chatLatestBottomConfirmationDelays(force: false), [0])
        XCTAssertEqual(chatLatestBottomConfirmationDelays(force: true), [0])
    }

    func testGroupAnnouncementDisplayContentIgnoresEmptyPlaceholderNotice() {
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: "", summary: " ", groupNotice: "暂无群公告"),
            ""
        )
        XCTAssertFalse(
            groupAnnouncementHasVisibleContent(content: nil, summary: nil, groupNotice: "暂无群公告")
        )
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: " 正文 ", summary: "摘要", groupNotice: "暂无群公告"),
            "正文"
        )
        XCTAssertEqual(
            groupAnnouncementDisplayContent(content: "", summary: " 摘要 ", groupNotice: "公告占位"),
            "摘要"
        )
    }

    func testPublishingGroupAnnouncementReportsMissingGroupInsteadOfSilentFailure() {
        let state = AppState()
        var didComplete: Bool?

        state.publishGroupAnnouncement(groupID: "missing-group", title: "群公告", content: "公告内容") { success in
            didComplete = success
        }

        XCTAssertEqual(didComplete, false)
        XCTAssertEqual(state.toast, "群资料同步中，请稍后再试")
    }

    func testSocialGroupDescriptionPolicyTrimsClearsAndCountsUnicodeScalars() throws {
        XCTAssertEqual(try GroupDescriptionInputPolicy.normalize("  群描述  \n"), "群描述")
        XCTAssertEqual(try GroupDescriptionInputPolicy.normalize(" \n "), "")
        XCTAssertEqual(
            GroupDescriptionInputPolicy.normalizedUnicodeScalarCount("  \(String(repeating: "a", count: 500))  "),
            500
        )
        XCTAssertEqual(
            try GroupDescriptionInputPolicy.normalize(String(repeating: "a", count: 500)).unicodeScalars.count,
            500
        )
        XCTAssertThrowsError(try GroupDescriptionInputPolicy.normalize(String(repeating: "a", count: 501))) { error in
            XCTAssertEqual(error as? GroupDescriptionInputError, .tooLong)
        }
        XCTAssertThrowsError(
            try GroupDescriptionInputPolicy.normalize(String(repeating: "👨‍👩‍👧‍👦", count: 72))
        ) { error in
            XCTAssertEqual(error as? GroupDescriptionInputError, .tooLong)
        }
    }

    func testSocialGroupOwnerTransferIdempotencyReusesIntentAndQueuesAuthoritativeRefresh() {
        var state = GroupOwnerTransferIdempotencyState()
        var createdKeys = ["key-1", "key-2", "key-3"]
        let makeKey = { createdKeys.removeFirst() }

        let first = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        let retry = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        let changedTarget = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-2", makeKey: makeKey)
        XCTAssertEqual(first, retry)
        XCTAssertNotEqual(first, changedTarget)

        state.clear(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1")
        let completedIntent = state.key(scope: "tenant|owner", groupID: "group-1", targetUID: "member-1", makeKey: makeKey)
        XCTAssertNotEqual(first, completedIntent)

        let store = ContactStore()
        let refreshKey = "tenant|owner|group-1"
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: refreshKey, includeSecondaryData: true))
        XCTAssertFalse(store.beginGroupBundleRefresh(
            refreshKey: refreshKey,
            includeSecondaryData: true,
            queueIfAlreadyRunning: true
        ))
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: refreshKey))
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: refreshKey))
    }

    func testSocialFriendRequestPresentationSeparatesMerchantReviewCancellationAndIncomingActions() {
        let outgoing = FriendRequest(
            id: "outgoing",
            name: "目标",
            source: "我发出的申请",
            message: "等待企业审核",
            direction: "outgoing",
            tenantReviewStatus: "pending",
            peerReviewStatus: "tenant_review_pending",
            canRespond: false,
            accepted: false
        )
        XCTAssertTrue(outgoing.canCancel)
        XCTAssertEqual(outgoing.statusLabel, "等待对方通过")

        let incoming = FriendRequest(
            id: "incoming",
            name: "申请人",
            source: "好友申请",
            message: "等待企业审核",
            direction: "incoming",
            tenantReviewStatus: "pending",
            peerReviewStatus: "tenant_review_pending",
            canRespond: false,
            accepted: false
        )
        XCTAssertFalse(incoming.isPendingIncoming)
        XCTAssertFalse(incoming.canCancel)

        let cancelled = FriendRequest(
            id: "cancelled",
            name: "目标",
            source: "我发出的申请",
            message: "申请已取消",
            status: "cancelled",
            direction: "outgoing",
            canRespond: false,
            outcome: "application_cancelled",
            resolutionMode: "requester_cancel",
            accepted: false
        )
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertFalse(cancelled.canCancel)
        XCTAssertEqual(cancelled.statusLabel, "已取消")

        let suppressed = FriendRequest(
            id: "suppressed",
            name: "目标",
            source: "我发出的申请",
            message: "申请已受策略抑制",
            status: "suppressed",
            direction: "outgoing",
            canRespond: false,
            outcome: "application_suppressed",
            resolutionMode: "suppressed_by_policy",
            accepted: false
        )
        XCTAssertTrue(suppressed.isSuppressed)
        XCTAssertFalse(suppressed.isPendingOutgoing)
        XCTAssertFalse(suppressed.canCancel)
        XCTAssertFalse(suppressed.accepted)
        XCTAssertEqual(suppressed.statusLabel, "未投递")

        let expired = FriendRequest(
            id: "expired",
            name: "目标",
            source: "我发出的申请",
            message: "申请已过期",
            status: "expired",
            direction: "outgoing",
            canRespond: false,
            accepted: false
        )
        XCTAssertFalse(expired.isPendingOutgoing)
        XCTAssertFalse(expired.canCancel)
        XCTAssertEqual(expired.statusLabel, "已过期")

        XCTAssertTrue(AppState.isFriendRelationRealtimeEvent(event: "friend_application.cancelled", kind: "friend"))
    }

    func testSocialGroupAnnouncementReadCountsAreServerGatedAndScrubbedFailClosed() {
        let announcement = GroupAnnouncement(
            id: "announcement-1",
            groupID: "group-1",
            title: "标题",
            content: "正文",
            summary: "正文",
            createdBy: "owner",
            status: "published",
            createdAt: "2026-08-13T09:00:00Z",
            updatedAt: "2026-08-13T10:00:00.123456Z",
            publishedAt: "2026-08-13T09:00:00Z",
            unread: true,
            readAt: nil,
            displayPosition: "above_pinned_messages",
            readAction: "/api/tenant/groups/group-1/announcements/announcement-1/read",
            readCount: 2,
            unreadCount: 3,
            recipientCount: 5,
            canViewReadCounts: true
        )

        XCTAssertEqual(announcement.readCountSummary, "2 人已读 · 3 人未读 · 共 5 人")
        let scrubbed = announcement.scrubbingReadCounts()
        XCTAssertFalse(scrubbed.canViewReadCounts)
        XCTAssertNil(scrubbed.readCount)
        XCTAssertNil(scrubbed.unreadCount)
        XCTAssertNil(scrubbed.recipientCount)
        XCTAssertNil(scrubbed.readCountSummary)
        XCTAssertEqual(scrubbed.id, announcement.id)
        XCTAssertEqual(scrubbed.updatedAt, announcement.updatedAt)

        let staleResponse = GroupAnnouncementPrivacyProjection.sanitize(
            announcement,
            requestEpoch: 4,
            currentEpoch: 5
        )
        XCTAssertFalse(staleResponse.canViewReadCounts)
        XCTAssertNil(staleResponse.readCount)
        XCTAssertEqual(
            GroupAnnouncementPrivacyProjection.sanitize(
                announcement,
                requestEpoch: 5,
                currentEpoch: 5
            ).readCount,
            2
        )
    }

    func testSocialGroupAnnouncementRevisionMergeRejectsSlowSummaryAndReadRollback() {
        let newer = GroupAnnouncement(
            id: "announcement-1",
            groupID: "group-1",
            title: "新标题",
            content: "新正文",
            summary: "新正文",
            createdBy: "owner",
            status: "published",
            createdAt: "2026-08-13T09:00:00Z",
            updatedAt: "2026-08-13T10:00:00Z",
            publishedAt: "2026-08-13T09:00:00Z",
            unread: false,
            readAt: "2026-08-13T10:01:00Z",
            displayPosition: "above_pinned_messages",
            readAction: "",
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        var older = newer
        older = GroupAnnouncement(
            id: older.id,
            groupID: older.groupID,
            title: "旧标题",
            content: "旧正文",
            summary: "旧正文",
            createdBy: older.createdBy,
            status: older.status,
            createdAt: older.createdAt,
            updatedAt: "2026-08-13T09:30:00Z",
            publishedAt: older.publishedAt,
            unread: true,
            readAt: nil,
            displayPosition: older.displayPosition,
            readAction: older.readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        XCTAssertEqual(
            GroupAnnouncementRevisionProjection.preferred(
                existing: newer,
                incoming: older,
                existingRevision: Date(timeIntervalSince1970: 20),
                incomingRevision: Date(timeIntervalSince1970: 10)
            ).content,
            "新正文"
        )

        var sameRevisionUnread = newer
        sameRevisionUnread = GroupAnnouncement(
            id: sameRevisionUnread.id,
            groupID: sameRevisionUnread.groupID,
            title: sameRevisionUnread.title,
            content: sameRevisionUnread.content,
            summary: sameRevisionUnread.summary,
            createdBy: sameRevisionUnread.createdBy,
            status: sameRevisionUnread.status,
            createdAt: sameRevisionUnread.createdAt,
            updatedAt: sameRevisionUnread.updatedAt,
            publishedAt: sameRevisionUnread.publishedAt,
            unread: true,
            readAt: nil,
            displayPosition: sameRevisionUnread.displayPosition,
            readAction: sameRevisionUnread.readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
        XCTAssertFalse(
            GroupAnnouncementRevisionProjection.preferred(
                existing: newer,
                incoming: sameRevisionUnread,
                existingRevision: Date(timeIntervalSince1970: 20),
                incomingRevision: Date(timeIntervalSince1970: 20)
            ).unread
        )
    }

    func testConversationListDisplayTimestampTreatsPlainTimeAsToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 60 * 60)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 23,
            hour: 21,
            minute: 0
        )))

        let todayPlainTime = try XCTUnwrap(conversationListDisplayTimestamp("20:14", now: now, calendar: calendar))
        let yesterdayMonthDay = try XCTUnwrap(conversationListDisplayTimestamp("6月22日", now: now, calendar: calendar))
        let olderToday = try XCTUnwrap(conversationListDisplayTimestamp("15:34", now: now, calendar: calendar))

        XCTAssertGreaterThan(todayPlainTime, yesterdayMonthDay)
        XCTAssertGreaterThan(todayPlainTime, olderToday)
    }

    func testContactStoreResetClearsTransientState() {
        let store = ContactStore()
        XCTAssertTrue(store.beginContactsSync())
        store.setContactsSyncError("failed")
        store.remarks = ["u1": "Alice"]
        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: "r1"))
        store.markFriendRelationsLoaded()
        store.replaceKnownInboxIDs(["inbox1"])
        store.rememberSystemInboxReadLocally(id: "system1")
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: "group-1|announcement-1"))
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: "tenant-a|user-a|group-1", includeSecondaryData: false))
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: "tenant-a|user-a|group-1", includeSecondaryData: true))

        store.reset()

        XCTAssertFalse(store.isContactsSyncing())
        XCTAssertNil(store.contactsSyncError())
        XCTAssertTrue(store.remarks.isEmpty)
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())
        XCTAssertFalse(store.friendRelationsLoaded())
        XCTAssertFalse(store.hasKnownInboxIDs())
        XCTAssertFalse(store.hasLocallyReadSystemInboxIDs())
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertFalse(store.hasGroupBundleRefreshModes())
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
    }

    func testContactStoreFriendRelationsLoadedLifecycle() {
        let store = ContactStore()

        XCTAssertFalse(store.friendRelationsLoaded())

        store.markFriendRelationsLoaded()
        XCTAssertTrue(store.friendRelationsLoaded())

        store.reset()
        XCTAssertFalse(store.friendRelationsLoaded())
    }

    func testContactStoreGroupInviteApprovalProcessingLifecycle() {
        let store = ContactStore()

        XCTAssertTrue(store.processingGroupInviteApprovalIDs().isEmpty)
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())
        XCTAssertFalse(store.beginGroupInviteApprovalProcessing(requestID: ""))

        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: " request-1 "))
        XCTAssertFalse(store.beginGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertTrue(store.isGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertEqual(store.processingGroupInviteApprovalIDs(), ["request-1"])
        XCTAssertTrue(store.hasGroupInviteApprovalProcessingIDs())

        store.finishGroupInviteApprovalProcessing(requestID: " request-1 ")
        XCTAssertFalse(store.isGroupInviteApprovalProcessing(requestID: "request-1"))
        XCTAssertFalse(store.hasGroupInviteApprovalProcessingIDs())

        XCTAssertTrue(store.beginGroupInviteApprovalProcessing(requestID: "request-2"))
        store.reset()
        XCTAssertTrue(store.processingGroupInviteApprovalIDs().isEmpty)
    }

    func testContactStoreInboxRuntimeStateLifecycle() {
        let store = ContactStore()

        XCTAssertTrue(store.knownInboxIDs().isEmpty)
        XCTAssertFalse(store.hasKnownInboxIDs())
        XCTAssertFalse(store.isSystemInboxReadLocally(id: "system1"))

        store.replaceKnownInboxIDs(["inbox1"])
        XCTAssertEqual(store.knownInboxIDs(), ["inbox1"])
        XCTAssertTrue(store.hasKnownInboxIDs())

        store.mergeKnownInboxIDs(["inbox2", "inbox1"])
        XCTAssertEqual(store.knownInboxIDs(), ["inbox1", "inbox2"])

        store.rememberSystemInboxReadLocally(id: "")
        XCTAssertFalse(store.hasLocallyReadSystemInboxIDs())

        store.rememberSystemInboxReadLocally(id: "system1")
        XCTAssertTrue(store.isSystemInboxReadLocally(id: "system1"))
        XCTAssertTrue(store.hasLocallyReadSystemInboxIDs())

        store.reset()
        XCTAssertTrue(store.knownInboxIDs().isEmpty)
        XCTAssertFalse(store.isSystemInboxReadLocally(id: "system1"))
    }

    func testContactStoreContactsSyncStateAndErrorLifecycle() {
        let store = ContactStore()

        XCTAssertFalse(store.isContactsSyncing())
        XCTAssertNil(store.contactsSyncError())

        XCTAssertTrue(store.beginContactsSync())
        XCTAssertFalse(store.beginContactsSync())
        XCTAssertTrue(store.isContactsSyncing())

        store.setContactsSyncError("通讯录同步失败，请稍后重试")
        XCTAssertEqual(store.contactsSyncError(), "通讯录同步失败，请稍后重试")

        store.finishContactsSync()
        XCTAssertFalse(store.isContactsSyncing())

        XCTAssertTrue(store.beginContactsSync())
        XCTAssertNil(store.contactsSyncError())
        store.finishContactsSync()
    }

    func testContactStoreAnnouncementDetailLoadingKeyAndLifecycleDedupesRequests() {
        let store = ContactStore()
        let context = store.groupAnnouncementDetailLoadingKeyContext(
            groupID: " group-1 ",
            announcementID: " announcement-1 "
        )

        XCTAssertEqual(
            context,
            ContactStore.GroupAnnouncementDetailLoadingKeyContext(
                groupID: "group-1",
                announcementID: "announcement-1"
            )
        )
        XCTAssertEqual(context.loadingKey, "group-1|announcement-1")
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertFalse(store.beginGroupAnnouncementDetailLoading(loadingKey: " "))
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: " \(context.loadingKey) "))
        XCTAssertFalse(store.beginGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertTrue(store.isGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertTrue(store.hasAnnouncementDetailLoadingKeys())

        store.finishGroupAnnouncementDetailLoading(loadingKey: " \(context.loadingKey) ")

        XCTAssertFalse(store.isGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
        XCTAssertFalse(store.hasAnnouncementDetailLoadingKeys())
        XCTAssertTrue(store.beginGroupAnnouncementDetailLoading(loadingKey: context.loadingKey))
    }

    func testContactStoreGroupBundleRefreshLifecycleQueuesPendingFullRefreshAfterLightRefresh() {
        let store = ContactStore()
        let context = store.groupBundleRefreshKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            groupID: " group-1 "
        )

        XCTAssertEqual(
            context,
            ContactStore.GroupBundleRefreshKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                groupID: "group-1"
            )
        )
        XCTAssertEqual(context.refreshKey, "tenant-a|user-a|group-1")
        XCTAssertFalse(store.hasGroupBundleRefreshModes())
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: " ", includeSecondaryData: false))
        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: " \(context.refreshKey) ", includeSecondaryData: false))
        XCTAssertTrue(store.isGroupBundleRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertEqual(store.groupBundleRefreshIncludesSecondaryData(refreshKey: context.refreshKey), false)
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: false))
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: " \(context.refreshKey) "))
        XCTAssertFalse(store.isGroupBundleRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertFalse(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))

        XCTAssertTrue(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertEqual(store.groupBundleRefreshIncludesSecondaryData(refreshKey: context.refreshKey), true)
        XCTAssertFalse(store.beginGroupBundleRefresh(refreshKey: context.refreshKey, includeSecondaryData: true))
        XCTAssertFalse(store.hasGroupBundlePendingFullRefreshKeys())
        XCTAssertFalse(
            store.beginGroupBundleRefresh(
                refreshKey: context.refreshKey,
                includeSecondaryData: true,
                queueIfAlreadyRunning: true
            )
        )
        XCTAssertTrue(store.isGroupBundlePendingFullRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.finishGroupBundleRefresh(refreshKey: context.refreshKey))
    }

    func testConversationStoreResetClearsRuntimeStateAndCancelsTasks() throws {
        let store = ConversationStore()
        let warmTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        XCTAssertTrue(store.beginMessageSync(historyKey: "loading|c1", conversationID: "c1", showLoadingIndicator: true))
        store.setHistoryMessage(conversationID: "c1", message: "loading")
        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        XCTAssertTrue(store.beginApplyingFriend(conversationID: "c1"))
        store.setDirectFriendRequestContext(
            conversationID: "c1",
            context: DirectFriendRequestContext(
                targetUID: "u1",
                canApplyFriend: true,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            )
        )
        store.rememberRead(key: "c1", readSeq: 10)
        store.markOlderHistoryNeedsContinue(
            historyKey: "backfill|c1",
            conversationID: "c1",
            nextBackfillAfterSeq: 103,
            pageLimit: 100,
            message: "continue"
        )
        store.markHistoryUnavailable(historyKey: "reached|c1", conversationID: "c1", message: "done")
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "load|c1",
            conversationID: "c1",
            now: Date(),
            throttleInterval: 1
        ))
        store.rememberConversationBottomSeq(9, stateKey: "scope|c1")
        store.prepareActiveRealtimeConversationAutoRead(conversationID: "c1")
        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c1",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        let resetReactionExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "created_at": "2026-06-23T10:00:00Z",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.shouldApplyReactionExtra(resetReactionExtra))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1"))
        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        store.replaceWarmRefreshTask(refreshKey: "c1", task: warmTask)
        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "m1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "m2"))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "read|c1"))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: "pin|c1"))

        store.reset()

        XCTAssertFalse(store.hasHistoryLoadingIDs())
        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
        XCTAssertFalse(store.hasApplyingFriendIDs())
        XCTAssertFalse(store.hasDirectFriendRequestContexts())
        XCTAssertFalse(store.hasLocallyReadSeqs())
        XCTAssertFalse(store.hasHistoryBackfillAfterSeqs())
        XCTAssertFalse(store.hasHistoryReachedStartKeys())
        XCTAssertFalse(store.hasHistoryLoadRequestTimes())
        XCTAssertFalse(store.hasConfirmedConversationBottomSeqs())
        XCTAssertFalse(store.hasActiveRealtimeConversationAutoReadStates())
        XCTAssertFalse(store.hasAppliedReactionExtraKeys())
        XCTAssertFalse(store.hasHistorySyncErrorToastTimes())
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: "scope|c1"))
        XCTAssertFalse(store.hasWarmRefreshTasks())
        XCTAssertFalse(store.isMessageExtrasSyncInFlight(syncKey: "m1"))
        XCTAssertFalse(store.isMessageReceiptsSyncInFlight(syncKey: "m2"))
        XCTAssertFalse(store.isReadAckSyncInFlight(syncKey: "read|c1"))
        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: "pin|c1"))
        XCTAssertTrue(warmTask.isCancelled)
    }

    func testConversationStoreSidecarSyncLifecycleDedupesExtrasAndReceiptsIndependently() {
        let store = ConversationStore()

        XCTAssertFalse(store.beginMessageExtrasSync(syncKey: ""))
        XCTAssertFalse(store.beginMessageReceiptsSync(syncKey: ""))

        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageExtrasSyncInFlight(syncKey: "scope|c1"))
        XCTAssertFalse(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))

        store.finishMessageExtrasSync(syncKey: "scope|c1")
        XCTAssertFalse(store.isMessageExtrasSyncInFlight(syncKey: "scope|c1"))
        XCTAssertTrue(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))

        store.finishMessageReceiptsSync(syncKey: "scope|c1")
        XCTAssertFalse(store.isMessageReceiptsSyncInFlight(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
    }

    func testConversationStorePinnedMessagesRefreshKeyAndLifecycleUsesSyncEngine() {
        let store = ConversationStore()
        let context = store.pinnedMessagesRefreshKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " conversation-1 ",
            channelID: " group-1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.PinnedMessagesRefreshKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "conversation-1",
                channelID: "group-1"
            )
        )
        XCTAssertEqual(context.refreshKey, "tenant-a|user-a|conversation-1|group-1")
        XCTAssertFalse(store.beginPinnedMessagesRefresh(refreshKey: ""))
        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: ""))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.isPinnedMessagesRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertFalse(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: "tenant-a|user-a|conversation-2|group-2"))

        store.finishPinnedMessagesRefresh(refreshKey: context.refreshKey)

        XCTAssertFalse(store.isPinnedMessagesRefreshInFlight(refreshKey: context.refreshKey))
        XCTAssertTrue(store.beginPinnedMessagesRefresh(refreshKey: context.refreshKey))
    }

    func testConversationStoreMessageSidecarSyncKeyContextBuildsNormalizedStableKey() {
        let store = ConversationStore()
        var normalizationInputs: [String] = []

        let context = store.messageSidecarSyncKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            channelID: " peer-a ",
            channelType: " Direct ",
            suffix: " read ",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizationInputs.append("\(rawChannelID)|\(rawChannelType)")
                return " user-a:peer-a "
            }
        )

        XCTAssertEqual(normalizationInputs, [" peer-a | Direct "])
        XCTAssertEqual(
            context,
            ConversationStore.MessageSidecarSyncKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                channelID: "peer-a",
                channelType: "direct",
                normalizedChannelID: "user-a:peer-a",
                suffix: "read"
            )
        )
        XCTAssertEqual(context.syncKey, "tenant-a|user-a|direct|user-a:peer-a|read")

        let sparseContext = store.messageSidecarSyncKeyContext(
            tenantID: nil,
            imUID: " ",
            channelID: " raw ",
            channelType: " ",
            suffix: " extras ",
            normalizeChannelID: { _, _ in " " }
        )

        XCTAssertEqual(sparseContext.syncKey, "extras")
    }

    func testConversationStoreReadReceiptSidecarSyncTargetPreservesDeliveryAcrossDetailedReceiptConfig() {
        let store = ConversationStore()
        var conversation = makeConversation(
            id: "local-c1",
            kind: .group,
            unread: 0,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, isOutgoing: true)
        ]
        store.conversations = [conversation]

        let target = store.readReceiptSidecarSyncTarget(
            channelID: " remote-c1 ",
            channelType: " group ",
            readReceiptsEnabled: true,
            channelIDForConversation: { conversation in
                conversation.id == "local-c1" ? " remote-c1 " : conversation.id
            }
        )

        XCTAssertEqual(
            target,
            ConversationStore.ReadReceiptSidecarSyncTarget(channelID: "remote-c1", channelType: "group")
        )
        XCTAssertEqual(
            store.readReceiptSidecarSyncTarget(
                channelID: "remote-c1",
                channelType: "group",
                readReceiptsEnabled: false,
                channelIDForConversation: { _ in "remote-c1" }
            ),
            ConversationStore.ReadReceiptSidecarSyncTarget(channelID: "remote-c1", channelType: "group")
        )
        XCTAssertNil(
            store.readReceiptSidecarSyncTarget(
                channelID: " ",
                channelType: "group",
                readReceiptsEnabled: true,
                channelIDForConversation: { _ in "remote-c1" }
            )
        )

        conversation.messages = [makeMessage(id: "m3", seq: 3)]
        store.conversations = [conversation]
        XCTAssertNil(
            store.readReceiptSidecarSyncTarget(
                channelID: "remote-c1",
                channelType: "group",
                readReceiptsEnabled: true,
                channelIDForConversation: { _ in "remote-c1" }
            )
        )
    }

    func testConversationStoreConversationReadStateKeyContextBuildsStableKey() {
        let store = ConversationStore()
        var normalizationInputs: [String] = []

        let context = store.conversationReadStateKeyContext(
            channelID: " c1 ",
            channelType: " Group ",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizationInputs.append("\(rawChannelID)|\(rawChannelType)")
                return " normalized-c1 "
            }
        )

        XCTAssertEqual(normalizationInputs, [" c1 | Group "])
        XCTAssertEqual(
            context,
            ConversationStore.ConversationReadStateKeyContext(
                channelID: "c1",
                channelType: "group",
                normalizedChannelID: "normalized-c1"
            )
        )
        XCTAssertEqual(context.syncKey, "group|normalized-c1")

        let emptyContext = store.conversationReadStateKeyContext(
            channelID: " ",
            channelType: " ",
            normalizeChannelID: { _, _ in " " }
        )
        XCTAssertEqual(emptyContext.syncKey, "|")
    }

    func testConversationStoreConversationHistoryKeyContextBuildsStableKey() {
        let store = ConversationStore()

        let context = store.conversationHistoryKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " c1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.ConversationHistoryKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "c1"
            )
        )
        XCTAssertEqual(context.historyKey, "tenant-a|user-a|c1")

        let sparseContext = store.conversationHistoryKeyContext(
            tenantID: nil,
            imUID: " ",
            conversationID: " c2 "
        )
        XCTAssertEqual(sparseContext.historyKey, "c2")
    }

    func testConversationStoreActiveConversationScopedStateKeyContextBuildsScopeAndStableKey() {
        let store = ConversationStore()

        let context = store.activeConversationScopedStateKeyContext(
            tenantID: " tenant-a ",
            imUID: " user-a ",
            conversationID: " c1 "
        )

        XCTAssertEqual(
            context,
            ConversationStore.ActiveConversationScopedStateKeyContext(
                tenantID: "tenant-a",
                imUID: "user-a",
                conversationID: "c1"
            )
        )
        XCTAssertEqual(context.scope, "tenant-a|user-a")
        XCTAssertEqual(context.stateKey, "tenant-a|user-a|c1")

        let sparseContext = store.activeConversationScopedStateKeyContext(
            tenantID: nil,
            imUID: " ",
            conversationID: " c2 "
        )
        XCTAssertEqual(sparseContext.scope, "")
        XCTAssertEqual(sparseContext.stateKey, "|c2")
    }

    func testConversationStoreConversationBottomSeqMemoryIsMonotonicByStateKey() {
        let store = ConversationStore()

        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: " scope|c1 "), 0)

        store.rememberConversationBottomSeq(4, stateKey: " scope|c1 ")
        store.rememberConversationBottomSeq(2, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(8, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(0, stateKey: "scope|c1")
        store.rememberConversationBottomSeq(6, stateKey: "scope|c2")

        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|c1"), 8)
        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|c2"), 6)
        XCTAssertEqual(store.rememberedConversationBottomSeq(stateKey: "scope|missing"), 0)
    }

    func testConversationStoreActiveRealtimeAutoReadStateTracksActiveConversationAndFallbackIDs() {
        let store = ConversationStore()

        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))

        store.prepareActiveRealtimeConversationAutoRead(conversationID: " c1 ")
        XCTAssertEqual(store.activeRealtimeConversationAutoReadState(conversationID: "c1"), false)
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertFalse(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c2",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        XCTAssertNil(store.activeRealtimeConversationAutoReadState(conversationID: "c2"))

        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: " c1 ",
            activeConversationID: " c1 ",
            canAutoRead: true
        ))
        XCTAssertTrue(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertTrue(store.canAutoReadActiveRealtimeConversation(previousConversationID: "previous-id", channelID: "c1"))
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: "previous-id", channelID: "c2"))

        store.prepareActiveRealtimeConversationAutoRead(conversationID: "c1")
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))

        XCTAssertTrue(store.updateActiveRealtimeConversationAutoRead(
            conversationID: "c1",
            activeConversationID: "c1",
            canAutoRead: true
        ))
        store.clearActiveRealtimeConversationAutoRead(conversationID: " c1 ")
        XCTAssertFalse(store.canAutoReadActiveRealtimeConversation(previousConversationID: nil, channelID: "c1"))
        XCTAssertFalse(store.hasActiveRealtimeConversationAutoReadStates())
    }

    func testConversationStoreWarmRefreshTaskLifecycleReplacesFinishesAndCancelsByConversation() {
        let store = ConversationStore()
        func makeWarmTask() -> Task<Void, Never> {
            Task<Void, Never> {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        let first = makeWarmTask()
        let second = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: " tenant|user|c1 ", task: first)
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))

        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c1", task: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))

        store.finishWarmRefreshTask(refreshKey: " tenant|user|c1 ")
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))
        XCTAssertFalse(second.isCancelled)
        second.cancel()

        let sameConversation = makeWarmTask()
        let sameConversationOtherScope = makeWarmTask()
        let otherConversation = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c1", task: sameConversation)
        store.replaceWarmRefreshTask(refreshKey: "tenant|other-user|c1", task: sameConversationOtherScope)
        store.replaceWarmRefreshTask(refreshKey: "tenant|user|c2", task: otherConversation)

        store.cancelWarmRefreshTasks(conversationID: " c1 ")

        XCTAssertTrue(sameConversation.isCancelled)
        XCTAssertTrue(sameConversationOtherScope.isCancelled)
        XCTAssertFalse(otherConversation.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|user|c1"))
        XCTAssertFalse(store.hasWarmRefreshTask(refreshKey: "tenant|other-user|c1"))
        XCTAssertTrue(store.hasWarmRefreshTask(refreshKey: "tenant|user|c2"))

        store.cancelAllWarmRefreshTasks()
        XCTAssertTrue(otherConversation.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTasks())

        let emptyKeyTask = makeWarmTask()
        store.replaceWarmRefreshTask(refreshKey: " ", task: emptyKeyTask)
        XCTAssertTrue(emptyKeyTask.isCancelled)
        XCTAssertFalse(store.hasWarmRefreshTasks())
    }

    func testConversationStoreReactionExtraDedupeSkipsRepeatedKeysIncludingDefaultActionOnlyKey() throws {
        let store = ConversationStore()
        let extra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "created_at": "2026-06-23T10:00:00Z",
          "payload": {}
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(extra))
        XCTAssertFalse(store.shouldApplyReactionExtra(extra))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(extra.dedupeKey))
        XCTAssertEqual(store.appliedReactionExtraKeyCount(), 1)

        let emptyKeyExtra = try decodeRemoteExtra("""
        {
          "extra_type": "reaction",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.shouldApplyReactionExtra(emptyKeyExtra))
        XCTAssertFalse(store.shouldApplyReactionExtra(emptyKeyExtra))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(extra.dedupeKey))
        XCTAssertTrue(store.hasAppliedReactionExtraKey(emptyKeyExtra.dedupeKey))
        XCTAssertEqual(store.appliedReactionExtraKeyCount(), 2)
    }

    func testConversationStoreDedupedReactionAddRepairsMissingEmojiAfterReload() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true)
        ]
        store.conversations = [conversation]
        let extra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "add",
          "payload": { "display_name": "Reader One" },
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(extra))
        XCTAssertFalse(store.shouldApplyReactionExtra(extra))
        XCTAssertTrue(store.applyDedupedReactionExtraIfMissing(
            extra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertFalse(store.applyDedupedReactionExtraIfMissing(
            extra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))

        let message = store.conversations[0].messages[0]
        XCTAssertEqual(message.reactions, [
            Reaction(id: "m1_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ])
        XCTAssertEqual(message.reactionDetails.map(\.id), ["m1_reader-1_🔥"])
    }

    func testConversationStoreDedupedReactionRemoveRepairsOnlyMatchingOperatorEmoji() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.reactions = [
            Reaction(id: "m1_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ]
        message.reactionDetails = [
            ReactionDetail(id: "m1_reader-1_🔥", emoji: "🔥", user: makeUser(id: "reader-1"), time: "10:00")
        ]
        conversation.messages = [message]
        store.conversations = [conversation]
        let removeExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "remove",
          "payload": {},
          "created_at": "2026-06-23T10:01:00Z"
        }
        """)

        XCTAssertTrue(store.shouldApplyReactionExtra(removeExtra))
        XCTAssertFalse(store.shouldApplyReactionExtra(removeExtra))
        XCTAssertTrue(store.applyDedupedReactionExtraIfMissing(
            removeExtra,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertTrue(store.conversations[0].messages[0].reactions.isEmpty)
        XCTAssertTrue(store.conversations[0].messages[0].reactionDetails.isEmpty)

        var unrelatedConversation = makeConversation(id: "c2", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var unrelatedMessage = makeMessage(id: "m2", seq: 1, isOutgoing: true)
        unrelatedMessage.reactions = [
            Reaction(id: "m2_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ]
        unrelatedConversation.messages = [unrelatedMessage]
        store.conversations = [unrelatedConversation]
        let unmatchedRemove = try decodeRemoteExtra("""
        {
          "message_id": "m2",
          "channel_id": "remote-c2",
          "channel_type": "group",
          "operator_uid": "reader-2",
          "extra_type": "reaction",
          "emoji": "🔥",
          "action": "remove",
          "payload": {},
          "created_at": "2026-06-23T10:02:00Z"
        }
        """)

        XCTAssertFalse(store.applyDedupedReactionExtraIfMissing(
            unmatchedRemove,
            currentUserIDs: ["me"],
            makeReactionDetail: makeReactionDetail(from:id:)
        ))
        XCTAssertEqual(store.conversations[0].messages[0].reactions, [
            Reaction(id: "m2_🔥", emoji: "🔥", count: 1, reactedByMe: false)
        ])
    }

    func testConversationStoreHistorySyncErrorToastThrottleIsScopedByConversationAndResettable() {
        let store = ConversationStore()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: " c1 ", now: start, throttleInterval: 20))
        XCTAssertEqual(store.historySyncErrorToastTime(conversationID: "c1"), start)
        XCTAssertFalse(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(19.9), throttleInterval: 20))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c2", now: start.addingTimeInterval(5), throttleInterval: 20))
        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(20), throttleInterval: 20))
        XCTAssertFalse(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(39.9), throttleInterval: 20))

        store.reset()

        XCTAssertTrue(store.shouldShowHistorySyncErrorToast(conversationID: "c1", now: start.addingTimeInterval(40), throttleInterval: 20))
    }

    func testConversationStoreOlderHistoryAvailabilityPlanBuildsTargetAndSkipsUnavailableStates() {
        let store = ConversationStore()
        var conversation = makeConversation(id: " c1 ", unread: 0, lastMsgSeq: 8, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m8", seq: 8)
        ]

        let target = ConversationStore.OlderHistoryAvailabilityTarget(
            historyKey: "scope|c1",
            conversationID: "c1",
            oldestSeq: 2
        )
        XCTAssertEqual(
            store.olderHistoryAvailabilityPlan(for: conversation, historyKey: " scope|c1 "),
            .available(target)
        )
        XCTAssertEqual(
            store.olderHistoryAvailabilityTarget(for: conversation, historyKey: " scope|c1 "),
            target
        )

        store.markOlderHistoryReachedStart(historyKey: "scope|c1", conversationID: "c1", message: "done")
        XCTAssertEqual(
            store.olderHistoryAvailabilityPlan(for: conversation, historyKey: " scope|c1 "),
            .reachedStart(historyKey: "scope|c1", conversationID: "c1")
        )
        XCTAssertNil(store.olderHistoryAvailabilityTarget(for: conversation, historyKey: " scope|c1 "))

        let sparseStore = ConversationStore()
        var boundaryConversation = makeConversation(id: "c2", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        boundaryConversation.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        XCTAssertEqual(
            sparseStore.olderHistoryAvailabilityPlan(for: boundaryConversation, historyKey: "scope|c2"),
            .unavailable(historyKey: "scope|c2", conversationID: "c2")
        )

        var transientOnlyConversation = makeConversation(id: "c3", unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        transientOnlyConversation.messages = [
            makeMessage(id: "local_1", seq: 2),
            makeMessage(id: "failed", seq: 3, status: .failed)
        ]
        XCTAssertEqual(
            sparseStore.olderHistoryAvailabilityPlan(for: transientOnlyConversation, historyKey: "scope|c3"),
            .unavailable(historyKey: "scope|c3", conversationID: "c3")
        )
    }

    func testConversationStoreMessageReceiptsSyncPlanBuildsCommandAndSkipsInFlight() {
        let store = ConversationStore()
        let command = ConversationStore.MessageReceiptsSyncCommand(
            syncKey: "scope|c1",
            channelID: "c1",
            channelType: "group"
        )

        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "", channelID: "c1", channelType: "group"),
            .skip(
                ConversationStore.MessageReceiptsSyncCommand(syncKey: "", channelID: "c1", channelType: "group"),
                reason: "empty read receipt key"
            )
        )
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .sync(command)
        )

        XCTAssertTrue(store.beginMessageReceiptsSync(command))
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .skip(command, reason: "read receipts already in flight")
        )

        store.finishMessageReceiptsSync(syncKey: command.syncKey)
        XCTAssertEqual(
            store.messageReceiptsSyncPlan(
                syncKey: " scope|c2 ",
                channelID: " c2 ",
                channelType: " group ",
                afterSeq: -7,
                receiptType: " ",
                limit: 0
            ),
            .sync(
                ConversationStore.MessageReceiptsSyncCommand(
                    syncKey: "scope|c2",
                    channelID: "c2",
                    channelType: "group",
                    afterSeq: 0,
                    receiptType: "",
                    limit: 1
                )
            )
        )
    }

    func testConversationStoreMessageExtrasSyncPlanBuildsCommandAndSkipsInFlight() {
        let store = ConversationStore()
        let command = ConversationStore.MessageExtrasSyncCommand(
            syncKey: "scope|c1",
            channelID: "c1",
            channelType: "group"
        )

        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "", channelID: "c1", channelType: "group"),
            .skip(
                ConversationStore.MessageExtrasSyncCommand(syncKey: "", channelID: "c1", channelType: "group"),
                reason: "empty message extras key"
            )
        )
        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .sync(command)
        )

        XCTAssertTrue(store.beginMessageExtrasSync(command))
        XCTAssertEqual(
            store.messageExtrasSyncPlan(syncKey: "scope|c1", channelID: "c1", channelType: "group"),
            .skip(command, reason: "message extras already in flight")
        )

        store.finishMessageExtrasSync(syncKey: command.syncKey)
        XCTAssertEqual(
            store.messageExtrasSyncPlan(
                syncKey: " scope|c2 ",
                channelID: " c2 ",
                channelType: " group ",
                afterVersion: -3,
                limit: 0
            ),
            .sync(
                ConversationStore.MessageExtrasSyncCommand(
                    syncKey: "scope|c2",
                    channelID: "c2",
                    channelType: "group",
                    afterVersion: 0,
                    limit: 1
                )
            )
        )
    }

    func testConversationStoreReadAckSyncLifecycleUsesIndependentOperation() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let readAckRequest = SyncEngineRequest(
            operation: .readAck,
            historyKey: "group|c1",
            reason: "assert"
        )
        let receiptRequest = SyncEngineRequest(
            operation: .readReceipt,
            historyKey: "group|c1",
            reason: "assert"
        )

        XCTAssertFalse(store.beginReadAckSync(syncKey: ""))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1"))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: "group|c1"))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "group|c1"))
        XCTAssertTrue(engine.isInFlight(readAckRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))

        store.finishReadAckSync(syncKey: "group|c1")

        XCTAssertFalse(engine.isInFlight(readAckRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))
    }

    func testConversationStoreReadAckSyncPlanCoalescesHigherInFlightTargets() throws {
        let store = ConversationStore()
        let command = ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 11)

        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "", targetSeq: 11),
            .skip(ConversationStore.ReadAckCommand(syncKey: "", targetSeq: 11), reason: "empty read ack key")
        )

        store.rememberRead(key: "group|c1", readSeq: 10)
        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 10), .clearLocally(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 10)))
        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11), .remoteAck(command))

        XCTAssertTrue(store.beginReadAckSync(command))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11),
            .skip(command, reason: "read ack target already pending")
        )
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 12),
            .queue(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12))
        )
        XCTAssertTrue(store.queueReadAckSync(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12)))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 13),
            .queue(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13))
        )
        XCTAssertTrue(store.queueReadAckSync(ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13)))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 12),
            .skip(
                ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 12),
                reason: "read ack target already pending"
            )
        )

        let followup = try XCTUnwrap(store.finishReadAckSync(syncKey: "group|c1"))
        XCTAssertEqual(followup, ConversationStore.ReadAckCommand(syncKey: "group|c1", targetSeq: 13))
        store.rememberRead(key: "group|c1", readSeq: 11)

        XCTAssertEqual(store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 11), .clearLocally(command))
        XCTAssertEqual(
            store.readAckSyncPlan(syncKey: "group|c1", targetSeq: 13),
            .remoteAck(followup)
        )
    }

    func testConversationStoreReadAckClaimFinishCannotReleaseNewScopeGeneration() throws {
        let store = ConversationStore()
        let command = ConversationStore.ReadAckCommand(syncKey: "group|same-channel", targetSeq: 1)
        let oldClaim = try XCTUnwrap(store.beginReadAckSyncClaim(command))

        store.reset()

        let newClaim = try XCTUnwrap(store.beginReadAckSyncClaim(command))
        XCTAssertNil(store.finishReadAckSync(oldClaim))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: command.syncKey))
        XCTAssertNil(store.finishReadAckSync(newClaim))
        XCTAssertFalse(store.isReadAckSyncInFlight(syncKey: command.syncKey))
    }

    func testConversationStoreReadAckSyncDedupesByMonotonicTargetSeq() {
        let store = ConversationStore()
        store.rememberRead(key: "group|c1", readSeq: 10)

        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 9))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 10))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertTrue(store.isReadAckSyncInFlight(syncKey: "group|c1"))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 12))

        store.finishReadAckSync(syncKey: "group|c1")
        store.rememberRead(key: "group|c1", readSeq: 11)

        XCTAssertFalse(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 11))
        XCTAssertTrue(store.beginReadAckSync(syncKey: "group|c1", targetSeq: 12))
    }

    func testConversationStoreSidecarSyncUsesInjectedEngineOperationsIndependently() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let extraRequest = SyncEngineRequest(
            operation: .messageExtra,
            historyKey: "scope|c1",
            reason: "assert"
        )
        let receiptRequest = SyncEngineRequest(
            operation: .readReceipt,
            historyKey: "scope|c1",
            reason: "assert"
        )

        XCTAssertTrue(store.beginMessageExtrasSync(syncKey: "scope|c1"))
        XCTAssertTrue(store.beginMessageReceiptsSync(syncKey: "scope|c1"))
        XCTAssertTrue(engine.isInFlight(extraRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))

        store.finishMessageExtrasSync(syncKey: "scope|c1")
        XCTAssertFalse(engine.isInFlight(extraRequest))
        XCTAssertTrue(engine.isInFlight(receiptRequest))
    }

    func testConversationStoreApplyRemoteReadReceiptsMergesDetailedReceipts() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.unreadCount = 2
        conversation.messages = [message]
        store.conversations = [conversation]
        let receipt = try decodeRemoteReceipt("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "im_uid": "reader-1",
          "device_id": "ios",
          "receipt_type": "read",
          "channel_seq": 1,
          "created_at": "2026-06-23T10:00:00Z",
          "display_name": "Reader One"
        }
        """)

        let didApply = store.applyRemoteReadReceipts(
            [receipt],
            channelID: "remote-c1",
            readReceiptsEnabled: true,
            channelIDForConversation: { _ in "remote-c1" },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        )

        XCTAssertTrue(didApply)
        let updated = store.conversations[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertTrue(updated.canViewReadDetails)
        XCTAssertEqual(updated.readCount, 1)
        XCTAssertEqual(updated.unreadCount, 1)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.readBy.first?.device, "ios")
    }

    func testConversationStoreApplyRemoteReadReceiptsCanUseChannelSeqFallback() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "remote-c1", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true),
            makeMessage(id: "m4", seq: 4, isOutgoing: true),
            makeMessage(id: "incoming", seq: 2, isOutgoing: false)
        ]
        store.conversations = [conversation]
        let receipt = try decodeRemoteReceipt("""
        {
          "message_id": "",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "im_uid": "",
          "device_id": "",
          "receipt_type": "read",
          "channel_seq": 2
        }
        """)

        let didApply = store.applyRemoteReadReceipts(
            [receipt],
            channelID: "remote-c1",
            readReceiptsEnabled: true,
            channelIDForConversation: { $0.id },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        )

        XCTAssertTrue(didApply)
        XCTAssertEqual(store.conversations[0].messages[0].status, .read)
        XCTAssertEqual(store.conversations[0].messages[0].readCount, 1)
        XCTAssertEqual(store.conversations[0].messages[1].status, .sent)
        XCTAssertEqual(store.conversations[0].messages[2].status, .sent)
    }

    func testConversationStoreDeliveredReceiptIsMonotonicAndNeverDowngradesRead() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "remote-c1", kind: .direct, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var first = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        var second = makeMessage(id: "m2", seq: 2, status: .read, isOutgoing: true)
        second.readStateKnown = true
        conversation.messages = [first, second]
        store.conversations = [conversation]
        let delivered = try decodeRemoteReceipt("""
        {
          "message_id": "",
          "channel_id": "remote-c1",
          "channel_type": "direct",
          "from_uid": "sender-1",
          "receipt_type": "delivered",
          "channel_seq": 2
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceipts(
            [delivered],
            channelID: "remote-c1",
            readReceiptsEnabled: false,
            channelIDForConversation: { $0.id },
            makeReadReceipt: makeReadReceipt(from:conversation:)
        ))

        first = store.conversations[0].messages[0]
        second = store.conversations[0].messages[1]
        XCTAssertTrue(first.deliveryStateKnown)
        XCTAssertEqual(first.status, .sent)
        XCTAssertTrue(second.deliveryStateKnown)
        XCTAssertEqual(second.status, .read)
        XCTAssertTrue(second.readStateKnown)
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsUpdatesCountsReceiptsAndReactions() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        ]
        store.conversations = [conversation]
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": false,
          "read_count": 2,
          "unread_count": 1,
          "can_view_details": true,
          "items": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "im_uid": "reader-1",
              "device_id": "ios",
              "receipt_type": "read",
              "channel_seq": 1,
              "created_at": "2026-06-23T10:00:00Z",
              "display_name": "Reader One"
            }
          ],
          "unread_items": [
            {
              "im_uid": "reader-2",
              "display_name": "Reader Two",
              "device_id": "",
              "read_at": null
            }
          ],
          "reactions": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "operator_uid": "reader-1",
              "emoji": "ok",
              "action": "add",
              "payload": { "display_name": "Reader One" },
              "created_at": "2026-06-23T10:00:01Z"
            }
          ]
        }
        """)

        let didApply = store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: " m1 ",
            conversationID: " local-c1 ",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        )

        XCTAssertTrue(didApply)
        let updated = store.conversations[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertTrue(updated.canViewReadDetails)
        XCTAssertEqual(updated.readCount, 2)
        XCTAssertEqual(updated.unreadCount, 1)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.unreadBy.map(\.user.id), ["reader-2"])
        XCTAssertEqual(updated.unreadBy.first?.device, "未同步")
        XCTAssertEqual(updated.reactionDetails.map(\.id), ["m1_reader-1_ok"])
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsKeepsReadMembersOutOfUnreadSection() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        ]
        store.conversations = [conversation]
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": true,
          "read_count": 1,
          "unread_count": 3,
          "can_view_details": true,
          "items": [
            {
              "message_id": "m1",
              "channel_id": "remote-c1",
              "channel_type": "group",
              "im_uid": "reader-1",
              "device_id": "ios",
              "receipt_type": "read",
              "channel_seq": 1,
              "created_at": "2026-06-23T10:00:00Z",
              "display_name": "Reader One"
            }
          ],
          "unread_items": [
            {
              "im_uid": "reader-1",
              "display_name": "Reader One",
              "device_id": "ios",
              "read_at": null
            },
            {
              "im_uid": "reader-2",
              "display_name": "Reader Two",
              "device_id": "",
              "read_at": null
            },
            {
              "im_uid": "reader-3",
              "display_name": "Reader Three",
              "device_id": "web",
              "readAt": "2026-06-23T10:00:02Z"
            }
          ],
          "reactions": []
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversations[0].messages[0]
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.unreadBy.map(\.user.id), ["reader-2"])
        XCTAssertEqual(updated.unreadCount, 1)
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsClearsPrivateDetailsAndPreservesConfirmedRead() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        message.readBy = [makeReadReceipt(userID: "reader-1")]
        message.unreadBy = [makeReadReceipt(userID: "reader-2")]
        message.readCount = 1
        message.unreadCount = 2
        message.readStateKnown = true
        message.canViewReadDetails = true
        message.reactionDetails = [ReactionDetail(id: "old", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        conversation.messages = [message]
        store.conversations = [conversation]
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": false,
          "can_view_details": false,
          "items": [],
          "unread_items": [],
          "reactions": []
        }
        """)

        XCTAssertTrue(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversations[0].messages[0]
        XCTAssertEqual(updated.status, .read)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertFalse(updated.canViewReadDetails)
        XCTAssertTrue(updated.readBy.isEmpty)
        XCTAssertTrue(updated.unreadBy.isEmpty)
        XCTAssertNil(updated.readCount)
        XCTAssertNil(updated.unreadCount)
        XCTAssertEqual(updated.reactionDetails.map(\.id), ["old"])
    }

    func testConversationStoreApplyRemoteReadReceiptDetailsSkipsInvalidMissingOrIncomingTargets() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var incoming = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false)
        incoming.canViewReadDetails = false
        conversation.messages = [incoming]
        store.conversations = [conversation]
        let response = try decodeRemoteReadReceiptResponse("""
        {
          "read": true,
          "read_count": 1,
          "can_view_details": true,
          "items": [],
          "unread_items": [],
          "reactions": []
        }
        """)

        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: " ",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: " ",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "missing",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "missing",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))
        XCTAssertFalse(store.applyRemoteReadReceiptDetails(
            response: response,
            messageID: "m1",
            conversationID: "local-c1",
            makeReadReceipt: makeReadReceipt(from:conversation:),
            makeUnreadReceipt: makeUnreadReadReceipt(from:conversation:),
            makeReactionDetail: makeReactionDetail(from:)
        ))

        let updated = store.conversations[0].messages[0]
        XCTAssertEqual(updated.status, .sent)
        XCTAssertFalse(updated.readStateKnown)
        XCTAssertFalse(updated.canViewReadDetails)
        XCTAssertTrue(updated.readBy.isEmpty)
    }

    func testConversationStoreReadReceiptSummaryAndStripDetails() throws {
        let store = ConversationStore()
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "sender",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "read_status": "read",
          "read_count": 2,
          "read_at": "2026-06-23T10:00:00Z"
        }
        """)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)

        store.applyRemoteReadSummary(from: remote, to: &message, readReceiptsEnabled: true)

        XCTAssertEqual(message.status, .read)
        XCTAssertTrue(message.readStateKnown)
        XCTAssertEqual(message.readCount, 2)

        message.readBy = [makeReadReceipt(userID: "reader-1")]
        message.unreadBy = [makeReadReceipt(userID: "reader-2")]
        message.unreadCount = 3
        message.canViewReadDetails = true
        message.reactionDetails = [
            ReactionDetail(id: "r1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")
        ]
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertTrue(store.stripReadReceiptDetailsFromAllMessages())
        let stripped = store.conversations[0].messages[0]
        XCTAssertEqual(stripped.status, .sent)
        XCTAssertFalse(stripped.readStateKnown)
        XCTAssertFalse(stripped.canViewReadDetails)
        XCTAssertTrue(stripped.readBy.isEmpty)
        XCTAssertTrue(stripped.unreadBy.isEmpty)
        XCTAssertNil(stripped.readCount)
        XCTAssertNil(stripped.unreadCount)
        XCTAssertTrue(stripped.reactionDetails.isEmpty)
    }

    func testConversationStoreMessageExtraAppliesReactionDetailReadStateAndReminder() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isOutgoing: true)
        ]
        store.conversations = [conversation]
        let addExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "add",
          "payload": { "display_name": "Reader One" },
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        XCTAssertTrue(store.applyMessageReaction(
            messageID: addExtra.messageID,
            emoji: addExtra.emoji,
            operatorUID: addExtra.operatorUID,
            action: addExtra.action,
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReactionDetail(addExtra, makeReactionDetail: makeReactionDetail(from:id:)))
        store.applyReactionReadStateIfNeeded(addExtra, currentUserIDs: ["me"])
        store.markReactionReminderIfNeeded(
            addExtra,
            currentUserIDs: ["me"],
            activeConversationID: nil,
            channelIDForConversation: { _ in "remote-c1" }
        )

        var updated = store.conversations[0]
        XCTAssertTrue(updated.hasUnreadReaction)
        XCTAssertEqual(updated.unread, 1)
        XCTAssertEqual(updated.unreadReactionCount, 1)
        XCTAssertEqual(updated.messages[0].reactions, [
            Reaction(id: "m1_thumbs_up", emoji: "thumbs_up", count: 1, reactedByMe: false)
        ])
        XCTAssertEqual(updated.messages[0].reactionDetails.map(\.id), ["m1_reader-1_thumbs_up"])
        XCTAssertEqual(updated.messages[0].status, .read)
        XCTAssertTrue(updated.messages[0].readStateKnown)
        XCTAssertEqual(updated.messages[0].readCount, 1)

        let removeExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "reader-1",
          "extra_type": "reaction",
          "emoji": "thumbs_up",
          "action": "remove",
          "payload": {}
        }
        """)
        XCTAssertTrue(store.applyMessageReaction(
            messageID: removeExtra.messageID,
            emoji: removeExtra.emoji,
            operatorUID: removeExtra.operatorUID,
            action: removeExtra.action,
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReactionDetail(removeExtra, makeReactionDetail: makeReactionDetail(from:id:)))

        updated = store.conversations[0]
        XCTAssertTrue(updated.messages[0].reactions.isEmpty)
        XCTAssertTrue(updated.messages[0].reactionDetails.isEmpty)
    }

    func testConversationStoreOwnReactionRemoveIsIdempotentAfterOptimisticToggle() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isOutgoing: true)
        message.reactions = [
            Reaction(id: "m1_ok", emoji: "ok", count: 2, reactedByMe: true)
        ]
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertTrue(store.applyMessageReaction(
            messageID: "m1",
            emoji: "ok",
            operatorUID: "me",
            action: "remove",
            currentUserIDs: ["me"]
        ))
        XCTAssertTrue(store.applyMessageReaction(
            messageID: "m1",
            emoji: "ok",
            operatorUID: "me",
            action: "remove",
            currentUserIDs: ["me"]
        ))

        XCTAssertEqual(store.conversations[0].messages[0].reactions, [
            Reaction(id: "m1_ok", emoji: "ok", count: 1, reactedByMe: false)
        ])
    }

    func testConversationStorePinExtraAppliesByRemoteChannelID() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        store.conversations = [conversation]
        let pinExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "admin",
          "extra_type": "pin",
          "emoji": "",
          "action": "pin",
          "payload": { "pinned": true }
        }
        """)
        let unpinExtra = try decodeRemoteExtra("""
        {
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "operator_uid": "admin",
          "extra_type": "pin",
          "emoji": "",
          "action": "unpin",
          "payload": { "pinned": false }
        }
        """)

        XCTAssertTrue(store.applyRemotePinExtra(
            pinExtra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))
        XCTAssertTrue(store.conversations[0].messages[0].isPinned)

        XCTAssertTrue(store.applyRemotePinExtra(
            unpinExtra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))
        XCTAssertFalse(store.conversations[0].messages[0].isPinned)
    }

    func testConversationStoreApplyRemoteEditExtraUpdatesLoadedMessageAndPreview() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        var message = makeMessage(id: "m1", seq: 2, status: .read, isOutgoing: false, text: "old text")
        message.isEdited = false
        conversation.messages = [message]
        conversation.lastMessage = "old text"
        store.conversations = [conversation]
        let extra = try decodeRemoteExtra("""
        {
          "tenant_id": "tenant-1",
          "message_id": "m1",
          "channel_id": "remote-c1",
          "channel_type": "group",
          "channel_seq": 2,
          "version": 1024,
          "extra_type": "edit",
          "operator_uid": "u2",
          "action": "edit",
          "payload": {
            "content_type": "text",
            "edit_revision": 1,
            "payload": {"text": "edited from peer", "edit_revision": 1}
          },
          "created_at": "2026-06-23T10:02:00Z"
        }
        """)

        XCTAssertTrue(store.applyRemoteEditExtra(
            extra,
            normalizedChannelID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))

        XCTAssertEqual(store.conversations[0].messages[0].text, "edited from peer")
        XCTAssertTrue(store.conversations[0].messages[0].isEdited)
		XCTAssertEqual(store.conversations[0].messages[0].editRevision, 1)
        XCTAssertEqual(store.conversations[0].messages[0].status, .read)
        XCTAssertEqual(store.conversations[0].lastMessage, "edited from peer")
    }

	func testConversationStoreRemoteEditRevisionRejectsDuplicateAndOutOfOrderEvents() throws {
		let store = ConversationStore()
		var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
		var message = makeMessage(id: "m1", seq: 2, status: .read, isOutgoing: false, text: "original")
		message.contentType = "text"
		conversation.messages = [message]
		store.conversations = [conversation]
		let revisionTwo = try decodeRemoteExtra("""
		{"tenant_id":"tenant-1","message_id":"m1","channel_id":"remote-c1","channel_type":"group","channel_seq":2,"version":2048,"extra_type":"edit","operator_uid":"u2","payload":{"edit_revision":2,"payload":{"text":"revision two","edit_revision":2}}}
		""")
		let revisionOne = try decodeRemoteExtra("""
		{"tenant_id":"tenant-1","message_id":"m1","channel_id":"remote-c1","channel_type":"group","channel_seq":2,"version":1024,"extra_type":"edit","operator_uid":"u2","payload":{"edit_revision":1,"payload":{"text":"revision one","edit_revision":1}}}
		""")
		XCTAssertTrue(store.applyRemoteEditExtra(revisionTwo, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertFalse(store.applyRemoteEditExtra(revisionTwo, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertFalse(store.applyRemoteEditExtra(revisionOne, normalizedChannelID: "remote-c1", channelIDForConversation: { _ in "remote-c1" }))
		XCTAssertEqual(store.conversations[0].messages[0].text, "revision two")
		XCTAssertEqual(store.conversations[0].messages[0].editRevision, 2)
		XCTAssertEqual(store.conversations[0].messages[0].status, .read)
	}

    func testConversationStoreMergeMappedRemoteMessagesReplacesExistingWithEditedRemoteState() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var previousMessage = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: false, text: "old text")
        previousMessage.isEdited = false
        previous.messages = [previousMessage]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "u2",
          "content_type": "text",
          "payload": {"text": "edited from history sync"},
          "status": "edited",
          "read_status": "read",
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)
        var mapped = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: false, text: "edited from history sync")
        mapped.isEdited = remote.isEdited

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: mapped,
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        let updated = try XCTUnwrap(result.messages.first)
        XCTAssertEqual(updated.text, "edited from history sync")
        XCTAssertTrue(updated.isEdited)
        XCTAssertEqual(updated.status, .read)
    }

    func testConversationStoreMergeMappedRemoteMessagesReplacesMatchedPendingLocalEcho() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        previous.messages = [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "hello")
        ]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "client_msg_no": "local_1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "me",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)
        let mapped = makeMessage(id: "m1", seq: 1, isOutgoing: true, text: "hello")

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: mapped,
                    clientMessageIDs: ["local_1"],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: "local_1"
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true
        )

        XCTAssertEqual(result.messages.map(\.id), ["m1"])
        XCTAssertEqual(result.latestKnownSeq, 1)
        XCTAssertEqual(result.latestMessage?.id, "m1")
        XCTAssertTrue(result.incomingRealtimeMessages.isEmpty)
        XCTAssertEqual(result.pendingLocalFinalizations.map(\.localID), ["local_1"])
        XCTAssertEqual(result.pendingLocalFinalizations.first?.remoteMessage.id, "m1")
    }

    func testConversationStoreHistoryReplayDoesNotFinalizeDifferentPendingAttachment() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 101, lastReadSeq: 101)
        var oldRemote = makeMessage(id: "remote_old_1", seq: 101, status: .sent, isOutgoing: true, text: "same.jpg", kind: .image)
        oldRemote.attachmentName = "same.jpg"
        oldRemote.attachmentFileID = "file_old_1"
        oldRemote.attachmentSizeBytes = 200
        var pending = makeMessage(id: "local_first_1", seq: 0, status: .sending, isOutgoing: true, text: "same.jpg", kind: .image)
        pending.attachmentName = "same.jpg"
        pending.attachmentFileID = "file_first_1"
        pending.attachmentSizeBytes = 100
        previous.messages = [oldRemote, pending]
        store.conversations = [previous]
        let replay = try decodeRemoteMessage("""
        {
          "message_id": "remote_old_1",
          "client_msg_no": "local_old_1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 101,
          "from_uid": "me",
          "content_type": "image",
          "payload": {
            "file_name": "same.jpg",
            "file_id": "file_old_1",
            "size_bytes": 200,
            "media_category": "image"
          },
          "status": "normal",
          "created_at": "2026-06-23T10:00:01Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: replay,
                    message: oldRemote,
                    clientMessageIDs: ["local_old_1"],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: "local_first_1"
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        XCTAssertTrue(result.pendingLocalFinalizations.isEmpty)
        XCTAssertEqual(result.messages.map(\.id), ["local_first_1", "remote_old_1"])
    }

    func testConfirmedLocalMessageDoesNotUpgradeClientSuppliedSenderToAuthoritative() {
        let store = ConversationStore()
        var previous = makeMessage(
            id: "local-voice",
            senderId: "authenticated-actor",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        previous.senderProvenance = .unknown
        var clientSuppliedRemote = makeMessage(
            id: "remote-voice",
            senderId: "spoofed-actor",
            seq: 11,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        clientSuppliedRemote.senderProvenance = .clientSupplied

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: clientSuppliedRemote,
            remoteMessageID: "remote-voice",
            remoteDisplayTime: "10:00",
            remoteCreatedAt: Date(timeIntervalSince1970: 100),
            remoteChannelSeq: 11,
            readReceiptsEnabled: true
        )

        XCTAssertEqual(confirmed.senderId, "authenticated-actor")
        XCTAssertEqual(confirmed.senderProvenance, .clientSupplied)
    }

    func testConfirmedLocalMessagePreservesStructuredMentionProjection() {
        let store = ConversationStore()
        let localMention = MentionIdentity(
            imUID: "member-local",
            userID: "user-local",
            username: "local-account",
            displayText: "本地成员"
        )
        let authoritativeMention = MentionIdentity(
            imUID: "member-authoritative",
            userID: "user-authoritative",
            username: "authoritative-account",
            displayText: "权威成员"
        )
        var previous = makeMessage(
            id: "local-mention",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "@本地成员 请确认"
        )
        previous.mentionedUsers = [localMention]
        var remoteMapped = makeMessage(
            id: "remote-mention",
            seq: 13,
            status: .sent,
            isOutgoing: true,
            text: "@权威成员 请确认"
        )
        remoteMapped.mentionedUsers = [authoritativeMention]

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: remoteMapped,
            remoteMessageID: "remote-mention",
            remoteDisplayTime: "10:02",
            remoteCreatedAt: Date(timeIntervalSince1970: 102),
            remoteChannelSeq: 13,
            readReceiptsEnabled: true
        )

        XCTAssertFalse(confirmed.mentionAll)
        XCTAssertEqual(confirmed.mentionedUsers, [authoritativeMention])

        var remoteWithoutMentionProjection = remoteMapped
        remoteWithoutMentionProjection.mentionedUsers = []
        let confirmedFromIncompleteAck = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: remoteWithoutMentionProjection,
            remoteMessageID: "remote-mention-fallback",
            remoteDisplayTime: "10:03",
            remoteCreatedAt: Date(timeIntervalSince1970: 103),
            remoteChannelSeq: 14,
            readReceiptsEnabled: true
        )

        XCTAssertEqual(confirmedFromIncompleteAck.mentionedUsers, [localMention])
    }

    func testMessageMentionProjectionUsesStructuredCurrentActorIdentityOnly() {
        let currentActor = makeUser(id: "member-current", name: "重名成员")
        let otherActor = makeUser(id: "member-other", name: "重名成员")

        var visibleTextOnly = makeMessage(
            id: "text-only",
            senderId: "sender",
            seq: 1,
            isOutgoing: false,
            text: "@重名成员 请确认"
        )
        visibleTextOnly.mentionedUsers = []

        var mentionsOtherStableActor = visibleTextOnly
        mentionsOtherStableActor.mentionedUsers = [MentionIdentity(user: otherActor)]

        var mentionsCurrentStableActor = visibleTextOnly
        mentionsCurrentStableActor.mentionedUsers = [MentionIdentity(user: currentActor)]

        XCTAssertFalse(MessageMentionProjection.includes(visibleTextOnly, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(mentionsOtherStableActor, currentActor: currentActor))
        XCTAssertTrue(MessageMentionProjection.includes(mentionsCurrentStableActor, currentActor: currentActor))
    }

    func testMessageMentionProjectionCoversGroupAllAndRejectsDirectAndOutgoingNoise() {
        let currentActor = makeUser(id: "member-current", name: "当前成员")
        var groupAll = makeMessage(id: "group-all", senderId: "sender", seq: 1, isOutgoing: false)
        groupAll.mentionAll = true

        var directNoise = makeMessage(
            id: "direct-noise",
            senderId: "sender",
            seq: 2,
            isOutgoing: false,
            text: "当前成员"
        )
        directNoise.mentionedUsers = []

        var outgoing = makeMessage(id: "outgoing", senderId: currentActor.id, seq: 3, isOutgoing: true)
        outgoing.mentionedUsers = [MentionIdentity(user: currentActor)]

        XCTAssertTrue(MessageMentionProjection.includes(groupAll, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(directNoise, currentActor: currentActor))
        XCTAssertFalse(MessageMentionProjection.includes(outgoing, currentActor: currentActor))
    }

    func testConversationStoreRealtimeSequenceGapRecoveryOrdersDedupesAndConvergesOnRetry() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 41, lastReadSeq: 41)
        previous.messages = [makeMessage(id: "m41", seq: 41)]

        let remote42 = try decodeRemoteMessage(remoteMessageJSON(id: "m42", channelID: "c1", channelType: "group", seq: 42))
        let remote43 = try decodeRemoteMessage(remoteMessageJSON(id: "m43", channelID: "c1", channelType: "group", seq: 43))
        let mapped42 = ConversationStore.MappedRemoteMessage(
            remote: remote42,
            message: makeMessage(id: "m42", seq: 42),
            clientMessageIDs: [],
            isRemoteFromCurrentUser: false,
            matchedLocalID: nil
        )
        let mapped43 = ConversationStore.MappedRemoteMessage(
            remote: remote43,
            message: makeMessage(id: "m43", seq: 43),
            clientMessageIDs: [],
            isRemoteFromCurrentUser: false,
            matchedLocalID: nil
        )

        let outOfOrderComplete = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [mapped43, mapped42, mapped43],
            readReceiptsEnabled: true,
            fromRealtime: true
        )
        XCTAssertEqual(outOfOrderComplete.messages.map(\.channelSeq), [41, 42, 43])
        XCTAssertNil(outOfOrderComplete.sequenceRecoveryAfterSeq)

        let missingMiddle = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [mapped43],
            readReceiptsEnabled: true,
            fromRealtime: true
        )
        XCTAssertEqual(missingMiddle.messages.map(\.channelSeq), [41, 43])
        XCTAssertEqual(missingMiddle.sequenceRecoveryAfterSeq, 41)

        var retryBase = previous
        retryBase.lastMsgSeq = missingMiddle.latestKnownSeq
        retryBase.messages = missingMiddle.messages
        let converged = store.mergeMappedRemoteMessages(
            previous: retryBase,
            mappedRemoteMessages: [mapped43, mapped42],
            readReceiptsEnabled: true,
            fromRealtime: false
        )
        XCTAssertEqual(converged.messages.map(\.id), ["m41", "m42", "m43"])
        XCTAssertEqual(Set(converged.messages.map(\.id)).count, 3)
    }

    func testConfirmedLocalMessageUsesAuthoritativeStoredSender() {
        let store = ConversationStore()
        var previous = makeMessage(
            id: "local-voice",
            senderId: "local-value",
            seq: 0,
            status: .sending,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        previous.senderProvenance = .unknown
        previous.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        var authoritativeRemote = makeMessage(
            id: "remote-voice",
            senderId: "stored-actor",
            seq: 12,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        authoritativeRemote.senderProvenance = .authoritativeStored
        authoritativeRemote.attachmentUploadFailure = AttachmentUploadFailure(code: .http, httpStatus: 503)

        let confirmed = store.confirmedLocalMessage(
            previous: previous,
            remoteMapped: authoritativeRemote,
            remoteMessageID: "remote-voice",
            remoteDisplayTime: "10:01",
            remoteCreatedAt: Date(timeIntervalSince1970: 101),
            remoteChannelSeq: 12,
            readReceiptsEnabled: true
        )

        XCTAssertNil(confirmed.attachmentUploadFailure)
        XCTAssertEqual(confirmed.senderId, "stored-actor")
        XCTAssertEqual(confirmed.senderProvenance, .authoritativeStored)
    }

    func testBatchForwardActorFailsClosedWithoutAuthenticatedIMUID() {
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: nil,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        )
        let state = AppState(
            api: IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: FakeHTTPTransport(results: [])
            ),
            apiContextOverride: context
        )
        var conversation = makeConversation(
            id: "group-voice",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var voice = makeMessage(
            id: "voice-1",
            senderId: state.currentUser.id,
            seq: 1,
            status: .sent,
            isOutgoing: true,
            text: "voice",
            kind: .voice
        )
        voice.senderProvenance = .authoritativeStored
        conversation.messages = [voice]
        state.conversationStore.conversations = [conversation]

        state.beginBatchForward(
            conversationID: conversation.id,
            initialMessageID: voice.id
        )

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        XCTAssertEqual(state.toast, "登录会话不可用，请重新登录")
    }

    func testLogoutScopeChangeClearsIdleBatchForwardDraftBeforeConversationIDReuse() {
        let state = AppState(
            api: makeCallEndingAPI(
                transport: FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "reused-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-before-logout",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        state.conversationStore.conversations = [source]
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )

        XCTAssertNotNil(state.batchForwardState)
        XCTAssertEqual(state.batchForwardSourceConversationID, source.id)

        state.logout()

        var reused = source
        reused.messages = [
            makeMessage(
                id: "source-after-logout",
                senderId: "different-scope-user",
                seq: 1
            )
        ]
        state.conversationStore.conversations = [reused]
        state.refreshBatchForwardContext(conversationID: reused.id)

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
    }

    func testLogoutKeepsFailClosedCleanupFailureVisible() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logout-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"),
            forceCleanupTombstoneFailureForTesting: true,
            forceScopeCleanupFallbackFailureForTesting: true
        )
        let state = AppState(
            api: makeCallEndingAPI(
                transport: FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
            ),
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            protectedSessionStore: IMKeychainSessionStore(
                simulatorFileURL: root.appendingPathComponent("session.json")
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )

        state.logout()

        XCTAssertEqual(
            state.toast,
            "本机数据安全清理失败，已阻止旧作用域缓存访问"
        )
    }

    func testLogoutScopeChangeCancelsSubmittingBatchForwardRequestAndClearsDraft() async {
        let transport = BatchForwardLifecycleHTTPTransport(
            behavior: .waitForCancellation
        )
        let state = AppState(
            api: makeCallEndingAPI(
                transport: transport
            ),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "batch-source",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        let target = makeConversation(
            id: "batch-target",
            kind: .group,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        state.conversationStore.conversations = [source, target]
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )
        state.toggleBatchForwardTarget(target)
        state.submitBatchForward()

        for _ in 0..<100 where !transport.didStartForwardRequest {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(transport.didStartForwardRequest)
        guard case .submitting = state.batchForwardState?.submissionPhase else {
            XCTFail("expected submitting batch-forward draft")
            return
        }

        state.logout()

        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        for _ in 0..<100 where !transport.didObserveCancellation {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(transport.didObserveCancellation)
    }

    func testSourceConversationExitCancelsAndFencesLateBatchForwardCompletion() async {
        let transport = BatchForwardLifecycleHTTPTransport(
            behavior: .returnCommittedAfterCancellation
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var source = makeConversation(
            id: "source-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        let target = makeConversation(
            id: "target-conversation",
            kind: .group,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        state.conversationStore.conversations = [source, target]
        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )
        state.toggleBatchForwardTarget(target)
        state.submitBatchForward()

        for _ in 0..<100 where !transport.didStartForwardRequest {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        state.leaveBatchForwardSourceConversation(source.id)
        for _ in 0..<100 where !transport.didReturnForwardResponse {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(transport.didObserveCancellation)
        XCTAssertTrue(transport.didReturnForwardResponse)
        XCTAssertNil(state.batchForwardState)
        XCTAssertNil(state.batchForwardSourceConversationID)
        XCTAssertNotEqual(state.toast, "已转发 1 条消息到 1 个会话")
    }

    func testBatchForwardCandidatesIncludeFriendAndGroupWithoutExistingConversationAndAllowSourceTarget() {
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let friend = makeUser(id: "friend-no-chat", name: "未聊好友")
        state.contacts = [friend]
        let sourceGroup = GroupInfo(
            id: "source-group",
            name: "来源群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        let groupWithoutConversation = GroupInfo(
            id: "group-no-chat",
            name: "未聊群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        state.groups = [sourceGroup, groupWithoutConversation]
        var source = makeConversation(
            id: sourceGroup.id,
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(
            id: "source-message",
            senderId: "uid-1",
            seq: 1,
            isOutgoing: true
        )
        message.senderProvenance = .authoritativeStored
        source.messages = [message]
        state.conversationStore.conversations = [source]

        state.beginBatchForward(
            conversationID: source.id,
            initialMessageID: message.id
        )

        let candidates = state.batchForwardTargetCandidates()
        let keys = Set(candidates.map(\.identityKey))
        XCTAssertTrue(keys.contains("direct|friend-no-chat:uid-1"))
        XCTAssertTrue(keys.contains("group|group-no-chat"))
        XCTAssertTrue(keys.contains("group|source-group"))
        XCTAssertEqual(
            Set(state.batchForwardState.map {
                Array($0.targetsByIdentity.keys)
            } ?? []),
            keys
        )

        for key in [
            "direct|friend-no-chat:uid-1",
            "group|group-no-chat",
            "group|source-group"
        ] {
            let candidate = candidates.first { $0.identityKey == key }
            XCTAssertNotNil(candidate)
            if let candidate {
                state.toggleBatchForwardTarget(candidate.target)
            }
        }
        XCTAssertEqual(state.batchForwardState?.selectedTargets.count, 3)
    }

    func testConversationStoreMergeMappedRemoteMessagesPreservesSidecarStateAndAppliesReadSummary() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var previousMessage = makeMessage(id: "m1", seq: 1, status: .read, isOutgoing: true)
        previousMessage.reactions = [
            Reaction(id: "m1_ok", emoji: "ok", count: 2, reactedByMe: true)
        ]
        previousMessage.readBy = [makeReadReceipt(userID: "reader-1")]
        previousMessage.readCount = 2
        previousMessage.readStateKnown = true
        previous.messages = [previousMessage]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "me",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "read_status": "read",
          "read_count": 3,
          "created_at": "2026-06-23T10:00:00Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: makeMessage(id: "m1", seq: 1, isOutgoing: true),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: true,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false
        )

        let updated = try XCTUnwrap(result.messages.first)
        XCTAssertEqual(updated.status, .read)
        XCTAssertEqual(updated.readCount, 3)
        XCTAssertTrue(updated.readStateKnown)
        XCTAssertEqual(updated.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(updated.reactions, previousMessage.reactions)
    }

    func testConversationStoreMergeMappedRemoteMessagesRetainsLatestTailWindowAndPinnedContext() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        var pinnedContext = makeMessage(id: "pinned-context", seq: 2, text: "old pinned")
        pinnedContext.isPinned = true
        pinnedContext.isPinnedContextOnly = true
        previous.messages = [pinnedContext] + (1...8).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        } + [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "pending")
        ]
        let remote9 = try decodeRemoteMessage("""
        {"message_id":"m9","channel_id":"c1","channel_type":"group","channel_seq":9,"from_uid":"u9","content_type":"text","payload":{"text":"nine"},"status":"sent"}
        """)
        let remote10 = try decodeRemoteMessage("""
        {"message_id":"m10","channel_id":"c1","channel_type":"group","channel_seq":10,"from_uid":"u10","content_type":"text","payload":{"text":"ten"},"status":"sent"}
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote9,
                    message: makeMessage(id: "m9", seq: 9),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                ),
                ConversationStore.MappedRemoteMessage(
                    remote: remote10,
                    message: makeMessage(id: "m10", seq: 10),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: false,
            windowRetention: .latestTail(limit: 5)
        )

        XCTAssertEqual(
            result.messages.map(\.id),
            ["local_1", "pinned-context", "m6", "m7", "m8", "m9", "m10"]
        )
        XCTAssertEqual(result.latestKnownSeq, 10)
        XCTAssertEqual(result.latestMessage?.id, "m10")
    }

    func testConversationStoreTrimConversationToLatestWindowKeepsPendingAndPinnedContext() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        var pinnedContext = makeMessage(id: "pinned-context", seq: 2, text: "old pinned")
        pinnedContext.isPinned = true
        pinnedContext.isPinnedContextOnly = true
        conversation.messages = [pinnedContext] + (1...8).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        } + [
            makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "pending")
        ]
        store.conversations = [conversation]

        XCTAssertTrue(store.trimConversationToLatestWindow(conversationID: "c1", limit: 3))

        XCTAssertEqual(
            store.conversations[0].messages.map(\.id),
            ["local_1", "pinned-context", "m6", "m7", "m8"]
        )
    }

    func testConversationStoreMergeMappedRemoteMessagesTracksIncomingRealtimeOnlyForNewRemoteMessages() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        previous.messages = [
            makeMessage(id: "m1", seq: 1)
        ]
        let remote = try decodeRemoteMessage("""
        {
          "message_id": "m2",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 2,
          "from_uid": "other",
          "content_type": "text",
          "payload": {},
          "status": "normal",
          "created_at": "2026-06-23T10:01:00Z"
        }
        """)

        let result = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: remote,
                    message: makeMessage(id: "m2", seq: 2, isOutgoing: false),
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true
        )

        XCTAssertEqual(result.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(result.incomingRealtimeMessages.map(\.id), ["m2"])
        XCTAssertEqual(result.latestKnownSeq, 2)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationIncrementsUnreadAndFlagsSoundForInactiveRealtime() {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        previous.time = "09:59"
        previous.sortTimestamp = 100
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.conversations = [previous]

        var latest = makeMessage(id: "m2", seq: 2, isOutgoing: false, text: "hello", time: "10:01")
        latest.createdAt = Date(timeIntervalSince1970: 200)
        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "remote-c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [previous.messages[0], latest],
            latestMessage: latest,
            incomingRealtimeMessages: [latest],
            latestKnownSeq: 2,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 8,
            accentHex: 42,
            avatarURL: "https://example.com/avatar.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "2026-06-23T10:01:00Z"
        )

        XCTAssertEqual(result.conversation.id, "c1")
        XCTAssertEqual(result.conversation.unread, 2)
        XCTAssertEqual(result.conversation.time, "10:01")
        XCTAssertEqual(result.conversation.sortTimestamp, 200)
        XCTAssertEqual(result.conversation.lastMsgSeq, 2)
        XCTAssertEqual(result.conversation.memberCount, 8)
        XCTAssertEqual(result.conversation.avatarVersion, "v2")
        XCTAssertEqual(result.incomingRealtimeMessages.map(\.id), ["m2"])
        XCTAssertTrue(result.shouldPlayIncomingSound)
        XCTAssertFalse(result.shouldAutoRead)
        XCTAssertEqual(store.conversations.first?.id, "c1")
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationAutoReadsActiveRealtimeAndUpdatesPulledLatest() {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        previous.time = "09:59"
        previous.sortTimestamp = 500
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.conversations = [previous]

        var realtimeLatest = makeMessage(id: "m2", seq: 2, isOutgoing: false, text: "active", time: "10:01")
        realtimeLatest.createdAt = Date(timeIntervalSince1970: 600)
        let realtimeResult = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [previous.messages[0], realtimeLatest],
            latestMessage: realtimeLatest,
            incomingRealtimeMessages: [realtimeLatest],
            latestKnownSeq: 2,
            fromRealtime: true,
            isActiveRealtimeConversation: true,
            canAutoReadActiveRealtimeConversation: true,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(realtimeResult.conversation.unread, 0)
        XCTAssertTrue(realtimeResult.shouldAutoRead)
        XCTAssertFalse(realtimeResult.shouldPlayIncomingSound)

        var historyPrevious = makeConversation(id: "c2", kind: .direct, unread: 3, lastMsgSeq: 10, lastReadSeq: 7)
        historyPrevious.time = "昨天"
        historyPrevious.sortTimestamp = 1_000
        historyPrevious.messages = [makeMessage(id: "h1", seq: 10, text: "old")]
        store.conversations = [historyPrevious]
        var historyLatest = makeMessage(id: "h2", seq: 11, text: "newer history", time: "今天")
        historyLatest.createdAt = Date(timeIntervalSince1970: 2_000)

        let historyResult = store.applyMergedRemoteMessagesConversation(
            channelID: "c2",
            kind: .direct,
            previous: historyPrevious,
            title: "Direct",
            subtitle: "单聊",
            participants: [],
            messages: [historyPrevious.messages[0], historyLatest],
            latestMessage: historyLatest,
            incomingRealtimeMessages: [],
            latestKnownSeq: 11,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 7,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(historyResult.conversation.unread, 3)
        XCTAssertEqual(historyResult.conversation.lastMessage, "newer history")
        XCTAssertEqual(historyResult.conversation.time, "今天")
        XCTAssertEqual(historyResult.conversation.sortTimestamp, 2_000)
        XCTAssertFalse(historyResult.shouldAutoRead)
        XCTAssertFalse(historyResult.shouldPlayIncomingSound)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationPreservesDirectPeerIdentityWhenProjectionIsBlank() {
        let store = ConversationStore()
        let currentUser = makeUser(id: "current-user", name: "Current User")
        let peer = makeUser(id: "peer-user", name: "Known Peer")
        var previous = makeConversation(id: "current-user:peer-user", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        previous.title = peer.name
        previous.participants = [currentUser, peer]
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        store.conversations = [previous]

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: previous.id,
            kind: .direct,
            previous: previous,
            title: "  ",
            subtitle: "单聊",
            participants: [],
            messages: previous.messages,
            latestMessage: previous.messages[0],
            incomingRealtimeMessages: [],
            latestKnownSeq: 1,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 7,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.title, "Known Peer")
        XCTAssertEqual(result.conversation.participants.map(\.id), ["current-user", "peer-user"])
    }

    func testConversationStoreAdvanceReadPreservesTailAcrossCoverageGapAndConvergesAfterRecovery() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "gap", kind: .group, unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [1, 2, 4].map { makeMessage(id: "m\($0)", seq: Int64($0), isOutgoing: false) }
        conversation.messageCoveredThroughSeq = 2
        conversation.messageCoverageRequiresRecovery = true
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 1
        conversation.firstUnreadMessageID = "m1"
        conversation.unreadAnchorSeq = 1
        conversation.unreadAnchorState = "resolved"
        store.conversations = [conversation]

        store.advanceRead(conversationID: conversation.id, through: 4)
        XCTAssertEqual(store.conversations[0].lastReadSeq, 2)
        XCTAssertEqual(store.conversations[0].unread, 1)
        XCTAssertEqual(store.conversations[0].firstUnreadSeq, 4)
        XCTAssertEqual(store.conversations[0].unreadAnchorSeq, 4)
        XCTAssertEqual(store.conversations[0].unreadAnchorState, "resolved")

        store.advanceRead(conversationID: conversation.id, through: 2)
        XCTAssertEqual(store.conversations[0].unread, 1)
        XCTAssertEqual(store.conversations[0].firstUnreadSeq, 4)

        store.conversations[0].messages.insert(makeMessage(id: "m3", seq: 3, isOutgoing: false), at: 2)
        store.conversations[0].messageCoveredThroughSeq = 4
        store.conversations[0].messageCoverageRequiresRecovery = false
        store.advanceRead(conversationID: conversation.id, through: 4)
        XCTAssertEqual(store.conversations[0].lastReadSeq, 4)
        XCTAssertEqual(store.conversations[0].unread, 0)
        XCTAssertEqual(store.conversations[0].firstUnreadSeq, 0)
        XCTAssertEqual(store.conversations[0].unreadAnchorState, "none")
    }

    func testConversationStorePartialReadPreservesMissingUnreadAnchorAndReactions() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "gap-anchor", kind: .group, unread: 4, lastMsgSeq: 4, lastReadSeq: 0)
        conversation.messages = [1, 2, 4].map { makeMessage(id: "m\($0)", seq: Int64($0), isOutgoing: false) }
        conversation.messageCoveredThroughSeq = 2
        conversation.messageCoverageRequiresRecovery = true
        conversation.firstUnreadSeq = 3
        conversation.firstUnreadMessageID = "m3"
        conversation.unreadAnchorSeq = 3
        conversation.unreadAnchorState = "unresolved"
        conversation.hasUnreadReaction = true
        conversation.unreadReactionCount = 1
        store.conversations = [conversation]

        store.advanceRead(conversationID: conversation.id, through: 2)
        store.advanceRead(conversationID: conversation.id, through: 2)
        XCTAssertEqual(store.conversations[0].unread, 2)
        XCTAssertEqual(store.conversations[0].firstUnreadSeq, 3)
        XCTAssertEqual(store.conversations[0].firstUnreadMessageID, "m3")
        XCTAssertEqual(store.conversations[0].unreadAnchorSeq, 3)
        XCTAssertEqual(store.conversations[0].unreadAnchorState, "unresolved")
        XCTAssertTrue(store.conversations[0].hasUnreadReaction)
        XCTAssertEqual(store.conversations[0].unreadReactionCount, 1)
    }

    func testConversationStoreAdvanceReadClearsUnreadWhenAckedIncomingPrecedesOwnOutgoingTail() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 1
        conversation.firstUnreadMessageID = "incoming-1"
        conversation.unreadAnchorSeq = 1
        conversation.messages = [
            makeMessage(id: "incoming-1", seq: 1, isOutgoing: false),
            makeMessage(id: "outgoing-2", seq: 2, isOutgoing: true)
        ]
        store.conversations = [conversation]

        store.advanceRead(conversationID: conversation.id, through: 1)

        let updated = store.conversations[0]
        XCTAssertEqual(updated.lastReadSeq, 1)
        XCTAssertEqual(updated.unread, 0)
        XCTAssertEqual(updated.firstUnreadSeq, 0)
        XCTAssertEqual(updated.firstUnreadMessageID, "")
        XCTAssertEqual(updated.unreadAnchorSeq, 0)
        XCTAssertEqual(updated.unreadAnchorState, "none")
    }

    func testConversationStoreAdvanceReadPreservesActualIncomingAndReactionFrontiers() {
        let store = ConversationStore()
        var incoming = makeConversation(id: "incoming", kind: .group, unread: 2, lastMsgSeq: 3, lastReadSeq: 0)
        incoming.hasUnreadReaction = false
        incoming.unreadReactionCount = 0
        incoming.firstUnreadSeq = 1
        incoming.firstUnreadMessageID = "incoming-1"
        incoming.unreadAnchorSeq = 1
        incoming.messages = [
            makeMessage(id: "incoming-1", seq: 1, isOutgoing: false),
            makeMessage(id: "incoming-2", seq: 2, isOutgoing: false),
            makeMessage(id: "outgoing-3", seq: 3, isOutgoing: true)
        ]
        var reaction = makeConversation(id: "reaction", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        reaction.hasUnreadReaction = true
        reaction.unreadReactionCount = 1
        reaction.messages = [makeMessage(id: "outgoing-2", seq: 2, isOutgoing: true)]
        store.conversations = [incoming, reaction]

        store.advanceRead(conversationID: incoming.id, through: 1)
        store.advanceRead(conversationID: reaction.id, through: 1)

        let updatedIncoming = store.conversations.first { $0.id == incoming.id }
        XCTAssertEqual(updatedIncoming?.unread, 1)
        XCTAssertEqual(updatedIncoming?.firstUnreadSeq, 2)
        XCTAssertEqual(updatedIncoming?.firstUnreadMessageID, "incoming-2")
        XCTAssertEqual(updatedIncoming?.unreadAnchorSeq, 2)
        let updatedReaction = store.conversations.first { $0.id == reaction.id }
        XCTAssertEqual(updatedReaction?.unread, 1)
        XCTAssertTrue(updatedReaction?.hasUnreadReaction == true)
        XCTAssertEqual(updatedReaction?.unreadReactionCount, 1)
    }

    func testConversationListMessageJumpTargetRejectsPlainConversationResult() {
        let conversationTarget = RemoteTenantSearchJumpTarget(
            kind: "conversation",
            channelID: "c1",
            channelType: "group",
            channelSeq: 8,
            messageID: nil
        )
        let messageTarget = RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: "c1",
            channelType: "group",
            channelSeq: 8,
            messageID: "m8"
        )

        XCTAssertNil(conversationListMessageJumpTarget(conversationTarget))
        XCTAssertEqual(conversationListMessageJumpTarget(messageTarget)?.messageID, "m8")
        XCTAssertEqual(conversationListMessageJumpTarget(messageTarget)?.channelSeq, 8)
    }

    func testChatPendingJumpWaitsForRenderedMessageAndAlwaysAllowsBottomAnchor() {
        XCTAssertFalse(chatCanConsumePendingScrollTarget(
            targetID: "m8",
            renderedMessageIDs: ["m7"],
            bottomAnchorID: "chat-bottom"
        ))
        XCTAssertTrue(chatCanConsumePendingScrollTarget(
            targetID: "m8",
            renderedMessageIDs: ["m7", "m8"],
            bottomAnchorID: "chat-bottom"
        ))
        XCTAssertTrue(chatCanConsumePendingScrollTarget(
            targetID: "chat-bottom",
            renderedMessageIDs: [],
            bottomAnchorID: "chat-bottom"
        ))
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationSeedsFirstUnreadForNewInactiveRealtime() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        previous.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2)
        ]
        store.conversations = [previous]

        var latest = makeMessage(id: "m3", seq: 3, isOutgoing: false, text: "new unread", time: "10:03")
        latest.createdAt = Date(timeIntervalSince1970: 300)

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: previous.messages + [latest],
            latestMessage: latest,
            incomingRealtimeMessages: [latest],
            latestKnownSeq: 3,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.unread, 1)
        XCTAssertEqual(result.conversation.lastReadSeq, 2)
        XCTAssertEqual(result.conversation.firstUnreadSeq, 3)
        XCTAssertEqual(result.conversation.firstUnreadMessageID, "m3")
        XCTAssertEqual(result.conversation.unreadAnchorSeq, 3)
        XCTAssertEqual(result.conversation.unreadAnchorState, "unread")

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: result.conversation.messages,
            unreadCount: result.conversation.unread,
            lastReadSeq: result.conversation.lastReadSeq,
            firstUnreadMessageID: result.conversation.firstUnreadMessageID,
            firstUnreadSeq: result.conversation.firstUnreadSeq,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertFalse(anchor.anchorsLastReadMessage)
    }

    func testConversationStoreApplyMergedRemoteMessagesConversationPreservesSortForOlderHistoryBackfill() {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 10, lastReadSeq: 10)
        previous.time = "10:00"
        previous.sortTimestamp = 1_000
        var latestKnown = makeMessage(id: "m10", seq: 10, text: "current latest", time: "10:00")
        latestKnown.createdAt = Date(timeIntervalSince1970: 1_000)
        var older = makeMessage(id: "m5", seq: 5, text: "older backfill", time: "09:00")
        older.createdAt = Date(timeIntervalSince1970: 500)
        previous.messages = [latestKnown]
        store.conversations = [previous]

        let result = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .group,
            previous: previous,
            title: "Group",
            subtitle: "群聊",
            participants: [],
            messages: [older, latestKnown],
            latestMessage: latestKnown,
            incomingRealtimeMessages: [],
            latestKnownSeq: 10,
            fromRealtime: false,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 2,
            accentHex: 42,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: ""
        )

        XCTAssertEqual(result.conversation.lastMessage, "current latest")
        XCTAssertEqual(result.conversation.time, "10:00")
        XCTAssertEqual(result.conversation.sortTimestamp, 1_000)
        XCTAssertEqual(result.conversation.lastMsgSeq, 10)
    }

    func testConversationStoreMergeRemoteConversationListKeepsIncrementalRowsAndReturnsSoundCandidates() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        previous.messages = [makeMessage(id: "m1", seq: 1)]
        previous.sortTimestamp = 100
        var retained = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        retained.sortTimestamp = 300
        store.conversations = [previous, retained]
        let remote = try decodeRemoteConversation("""
        {
          "channel_id": "c1",
          "channel_type": "group",
          "unread_count": 2,
          "last_msg_seq": 3,
          "version": 4
        }
        """)
        var mapped = makeConversation(id: "c1", kind: .group, unread: 2, lastMsgSeq: 3, lastReadSeq: 0)
        mapped.isPinned = true
        mapped.sortTimestamp = 200

        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "c1",
                    remote: remote,
                    conversation: mapped
                )
            ],
            replacing: false,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(store.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(store.conversations[0].unread, 2)
        XCTAssertEqual(result.soundCandidates.count, 1)
        XCTAssertEqual(result.soundCandidates.first?.previous.id, "c1")
        XCTAssertEqual(result.soundCandidates.first?.remote.channelID, "c1")
        XCTAssertEqual(result.soundCandidates.first?.mapped.lastMsgSeq, 3)
    }

    func testConversationStoreMergeRemoteConversationListDropsDuplicateConversationIDs() throws {
        let store = ConversationStore()
        let olderRemote = try decodeRemoteConversation("""
        {
          "channel_id": "legacy-channel",
          "channel_type": "group",
          "unread_count": 1,
          "last_msg_seq": 1,
          "version": 1
        }
        """)
        let newerRemote = try decodeRemoteConversation("""
        {
          "channel_id": "canonical-channel",
          "channel_type": "group",
          "unread_count": 5,
          "last_msg_seq": 5,
          "version": 5
        }
        """)
        var older = makeConversation(id: "same-conversation", kind: .group, unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "same-conversation", kind: .group, unread: 5, lastMsgSeq: 5, lastReadSeq: 0)
        newer.sortTimestamp = 300

        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "legacy-channel",
                    remote: olderRemote,
                    conversation: older
                ),
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "canonical-channel",
                    remote: newerRemote,
                    conversation: newer
                )
            ],
            replacing: true,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations.map(\.id), ["same-conversation"])
        XCTAssertEqual(store.conversations.map(\.id), ["same-conversation"])
        XCTAssertEqual(store.conversations.first?.unread, 5)
        XCTAssertEqual(store.conversations.first?.lastMsgSeq, 5)
    }

    func testConversationStoreMergeRemoteConversationListCanReplaceWithEmptyList() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "c1", unread: 1, lastMsgSeq: 1, lastReadSeq: 0)
        ]

        let result = store.mergeRemoteConversationList(
            entries: [],
            replacing: true,
            channelIDForConversation: { $0.id }
        )

        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(result.soundCandidates.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
    }

    func testConversationStoreMergeRemoteConversationListSkipsPublishWhenOrderAndContentUnchanged() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 1)
        conversation.isPinned = true
        conversation.sortTimestamp = 200
        store.conversations = [conversation]

        var emissionCount = 0
        let cancellable = store.$conversations
            .dropFirst()
            .sink { _ in
                emissionCount += 1
            }

        let remote = try decodeRemoteConversation("""
        {
          "channel_id": "c1",
          "channel_type": "group",
          "unread_count": 1,
          "last_msg_seq": 3,
          "version": 4
        }
        """)
        let result = store.mergeRemoteConversationList(
            entries: [
                ConversationStore.RemoteConversationMergeEntry(
                    channelID: "c1",
                    remote: remote,
                    conversation: conversation
                )
            ],
            replacing: false,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(result.conversations, [conversation])
        XCTAssertEqual(store.conversations, [conversation])
        XCTAssertEqual(emissionCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testConversationStoreReplaceLocalMessageWithRemoteConfirmationMergesAttachmentAndSidecarState() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        var local = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "report.pdf", time: "09:59", kind: .file)
        local.createdAt = Date(timeIntervalSince1970: 100)
        local.attachmentName = "report.pdf"
        local.attachmentMeta = "application/pdf · 2 KB"
        local.attachmentFileID = "local-file"
        local.attachmentSizeBytes = 2048
        local.attachmentPreviewURL = "file:///tmp/local-preview.jpg"
        local.attachmentDownloadURL = "https://example.test/download"
        local.attachmentPreviewAvailable = true
        local.attachmentDownloadAvailable = true
        local.attachmentThumbnailURL = "file:///tmp/thumb.jpg"
        local.attachmentPosterURL = "https://example.test/poster"
        local.attachmentUploadStatus = "uploading"
        local.reactions = [Reaction(id: "local_1_ok", emoji: "ok", count: 1, reactedByMe: true)]
        local.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        local.readBy = [makeReadReceipt(userID: "reader-1")]
        local.readCount = 1
        local.readStateKnown = true
        local.isPinned = true
        local.isFavorited = true
        var remoteMapped = makeMessage(id: "remote-1", seq: 8, isOutgoing: true, text: "server text", time: "10:01", kind: .file)
        remoteMapped.attachmentFileID = "remote-file"
        remoteMapped.attachmentMimeType = "application/pdf"
        remoteMapped.attachmentCoverURL = "https://example.test/cover"
        remoteMapped.replyContext = MessageReplyContext(messageID: "source", summary: "source")
        conversation.messages = [local]
        store.conversations = [conversation]
        let remoteCreatedAt = Date(timeIntervalSince1970: 200)

        let replacement = try XCTUnwrap(store.replaceLocalMessageWithRemoteConfirmation(
            localID: "local_1",
            remoteMessageID: "remote-1",
            remoteMapped: remoteMapped,
            remoteDisplayTime: "10:01",
            remoteCreatedAt: remoteCreatedAt,
            remoteChannelSeq: 8,
            in: "c1",
            readReceiptsEnabled: true
        ))

        XCTAssertEqual(replacement.previousMessage.id, "local_1")
        let confirmed = replacement.confirmedMessage
        XCTAssertEqual(confirmed.id, "remote-1")
        XCTAssertEqual(confirmed.text, "report.pdf")
        XCTAssertEqual(confirmed.time, "10:01")
        XCTAssertEqual(confirmed.createdAt, remoteCreatedAt)
        XCTAssertEqual(confirmed.channelSeq, 8)
        XCTAssertEqual(confirmed.status, .read)
        XCTAssertEqual(confirmed.attachmentFileID, "remote-file")
        XCTAssertEqual(confirmed.attachmentPreviewURL, "")
        XCTAssertEqual(confirmed.attachmentDownloadURL, "https://example.test/download")
        XCTAssertEqual(confirmed.attachmentThumbnailURL, "")
        XCTAssertEqual(confirmed.attachmentPosterURL, "https://example.test/poster")
        XCTAssertEqual(confirmed.attachmentCoverURL, "https://example.test/cover")
        XCTAssertEqual(confirmed.attachmentUploadStatus, "uploaded")
        XCTAssertNil(confirmed.attachmentTransferProgress)
        XCTAssertEqual(confirmed.reactions, local.reactions)
        XCTAssertEqual(confirmed.reactionDetails, local.reactionDetails)
        XCTAssertEqual(confirmed.readBy.map(\.user.id), ["reader-1"])
        XCTAssertEqual(confirmed.readCount, 1)
        XCTAssertTrue(confirmed.isPinned)
        XCTAssertTrue(confirmed.isFavorited)
        XCTAssertEqual(confirmed.replyContext?.messageID, "source")
        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["remote-1"])
        XCTAssertEqual(store.conversations[0].lastMessage, "[PDF] report.pdf")
        XCTAssertEqual(store.conversations[0].time, "10:01")
    }

    func testAppStateAttachmentTransferProgressIgnoresCompletedUploadResidue() throws {
        let state = AppState()
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "photo.jpg", kind: .image)
        message.attachmentFileID = "file-1"
        message.attachmentUploadStatus = "uploading"
        message.attachmentTransferProgress = 0.88
        state.fileStore.setAttachmentDownloadProgress(0.88, attachmentID: "file-1")

        XCTAssertTrue(state.isAttachmentUploadInProgress(message))
        XCTAssertEqual(try XCTUnwrap(state.attachmentTransferProgress(for: message)), 0.88, accuracy: 0.001)

        message.status = .sent
        message.attachmentUploadStatus = "uploaded"

        XCTAssertFalse(state.isAttachmentUploadInProgress(message))
        XCTAssertNil(state.attachmentTransferProgress(for: message))
    }

    func testFileStoreResetClearsAttachmentRuntimeStateAndLocalResources() throws {
        let store = FileStore()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-store-local-resource-\(UUID().uuidString).txt")
        try Data("local-resource".utf8).write(to: localURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: localURL)
        }
        let downloadTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return localURL
        }
        defer {
            downloadTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: downloadTask)
        store.setAttachmentDownloadProgress(0.42, attachmentID: "file-1")
        store.markAttachmentDownloadFailed(attachmentID: "file-1")
        store.cacheLocalAttachmentResources(LocalAttachmentPreviewResources(
            previewURL: localURL,
            downloadURL: localURL,
            thumbnailURL: nil,
            width: nil,
            height: nil
        ), cacheKey: "scope|file-1")

        store.reset()

        XCTAssertTrue(downloadTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-1"))
    }

    func testFileStoreLocalAttachmentResourceCacheLifecycle() throws {
        let store = FileStore()
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("local-resource".utf8).write(to: localURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: localURL)
        }
        let resources = LocalAttachmentPreviewResources(
            previewURL: localURL,
            downloadURL: localURL,
            thumbnailURL: nil,
            width: 24,
            height: 12
        )

        store.cacheLocalAttachmentResources(resources, cacheKey: " scope|file-1 ")
        store.cacheLocalAttachmentResources(resources, cacheKeys: ["scope|file-2", " "])

        XCTAssertEqual(store.localAttachmentResources(cacheKey: "scope|file-1")?.width, 24)
        XCTAssertEqual(store.localAttachmentResources(cacheKey: " scope|file-2 ")?.height, 12)
        XCTAssertNil(store.localAttachmentResources(cacheKey: ""))

        store.clearLocalAttachmentResources(cacheKey: "scope|file-1")
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-1"))
        XCTAssertNotNil(store.localAttachmentResources(cacheKey: "scope|file-2"))

        store.clearLocalAttachmentResources()
        XCTAssertNil(store.localAttachmentResources(cacheKey: "scope|file-2"))
    }

    func testFileStoreGroupFilesSyncStateAndErrorsLifecycle() throws {
        let store = FileStore()
        let file = FileItem(
            id: "file-1",
            name: "report.pdf",
            type: "PDF",
            size: "2 KB",
            owner: "Mia",
            source: "产品内测群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group"
        )

        XCTAssertFalse(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))

        XCTAssertTrue(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertFalse(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertTrue(store.isGroupSyncing(groupID: "g_files"))

        store.setGroupSyncError("群文件同步失败，请稍后重试", groupID: "g_files")
        XCTAssertEqual(store.groupSyncError(groupID: "g_files"), "群文件同步失败，请稍后重试")

        store.replaceGroupFiles([file], groupID: "g_files")
        XCTAssertTrue(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["file-1"])

        store.finishGroupFilesSync(groupID: "g_files")
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))

        XCTAssertTrue(store.beginGroupFilesSync(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))
        store.finishGroupFilesSync(groupID: "g_files")

        store.reset()

        XCTAssertFalse(store.hasGroupFiles(groupID: "g_files"))
        XCTAssertFalse(store.isGroupSyncing(groupID: "g_files"))
        XCTAssertNil(store.groupSyncError(groupID: "g_files"))
    }

    func testFileStoreExcludesVoiceMessagesFromTenantAndGroupFileLists() {
        let store = FileStore()
        let regularAudio = FileItem(
            id: "audio-track",
            name: "meeting-theme.m4a",
            type: "音频",
            size: "12 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "file",
            mimeType: "audio/mp4"
        )
        let contentTypeVoice = FileItem(
            id: "voice-content-type",
            name: "recording.m4a",
            type: "音频",
            size: "8 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:01",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "voice",
            kind: "file",
            mimeType: "audio/mp4"
        )
        let mediaCategoryVoice = FileItem(
            id: "voice-media-category",
            name: "recording.webm",
            type: "音频",
            size: "9 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:02",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "voice",
            contentType: "file",
            kind: "file",
            mimeType: "audio/webm"
        )
        let kindVoice = FileItem(
            id: "voice-kind",
            name: "recording.amr",
            type: "音频",
            size: "7 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:03",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "voice",
            mimeType: "audio/amr"
        )
        let legacyVoice = FileItem(
            id: "voice-legacy",
            name: "voice-20260725140831.webm",
            type: "音频",
            size: "10 KB",
            owner: "Mia",
            source: "产品群",
            time: "10:04",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_files",
            channelType: "group",
            mediaCategory: "audio",
            contentType: "file",
            kind: "file",
            mimeType: "audio/webm"
        )
        let allFiles = [regularAudio, contentTypeVoice, mediaCategoryVoice, kindVoice, legacyVoice]

        store.replaceTenantFiles(allFiles)
        store.replaceGroupFiles(allFiles, groupID: "g_files")

        XCTAssertEqual(store.tenantFiles().map(\.id), ["audio-track"])
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["audio-track"])

        store.upsertTenantFile(contentTypeVoice)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["audio-track"])
        XCTAssertEqual(store.files(for: "g_files").map(\.id), ["audio-track"])

        store.mergeGroupFiles([contentTypeVoice])

        XCTAssertTrue(store.files(for: "g_files").isEmpty)
    }

    func testFileStorePurgesGroupHistoryBoundaryFilesAndFailsClosedUnsequencedItems() throws {
        let store = FileStore()
        let old = FileItem(
            id: "old",
            name: "old.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:00",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group",
            channelSeq: 420
        )
        let visible = FileItem(
            id: "visible",
            name: "visible.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:01",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group",
            channelSeq: 421
        )
        let unsequenced = FileItem(
            id: "unsequenced",
            name: "unknown.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "受限群",
            time: "10:02",
            scope: "群文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "g_history",
            channelType: "group"
        )
        let direct = FileItem(
            id: "direct",
            name: "direct.pdf",
            type: "PDF",
            size: "1 KB",
            owner: "Mia",
            source: "私聊",
            time: "10:03",
            scope: "私聊文件",
            status: "已上传",
            accentHex: 0x6677FF,
            channelID: "d_1",
            channelType: "direct",
            channelSeq: 1
        )

        store.replaceTenantFiles([old, visible, unsequenced, direct])
        store.replaceGroupFiles([old, visible, unsequenced], groupID: "g_history")

        store.purgeGroupHistoryFiles(groupID: "g_history", fromSeq: 421)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["visible", "direct"])
        XCTAssertEqual(store.files(for: "g_history").map(\.id), ["visible"])

        store.purgeGroupHistoryFiles(groupID: "g_history", fromSeq: 1, clearAll: true)

        XCTAssertEqual(store.tenantFiles().map(\.id), ["direct"])
        XCTAssertEqual(store.files(for: "g_history"), [])
    }

    func testFileStoreTenantFilesSyncStateAndErrorsLifecycle() throws {
        let store = FileStore()
        let file = FileItem(
            id: "file-1",
            name: "report.pdf",
            type: "PDF",
            size: "2 KB",
            owner: "Mia",
            source: "企业文件",
            time: "10:00",
            scope: "企业文件",
            status: "已上传",
            accentHex: 0x6677FF
        )

        XCTAssertFalse(store.hasTenantFiles())
        XCTAssertFalse(store.hasTenantFile(id: "file-1"))
        XCTAssertFalse(store.isTenantFilesSyncing())
        XCTAssertNil(store.tenantFilesSyncError())

        XCTAssertTrue(store.beginTenantFilesSync())
        XCTAssertFalse(store.beginTenantFilesSync())
        XCTAssertTrue(store.isTenantFilesSyncing())

        store.setTenantFilesSyncError("文件同步失败，当前显示上次缓存")
        XCTAssertEqual(store.tenantFilesSyncError(), "文件同步失败，当前显示上次缓存")

        store.replaceTenantFiles([file])
        XCTAssertTrue(store.hasTenantFiles())
        XCTAssertTrue(store.hasTenantFile(id: "file-1"))
        XCTAssertEqual(store.tenantFiles().map(\.id), ["file-1"])

        store.finishTenantFilesSync()
        XCTAssertFalse(store.isTenantFilesSyncing())

        XCTAssertTrue(store.beginTenantFilesSync())
        XCTAssertNil(store.tenantFilesSyncError())
        store.finishTenantFilesSync()

        store.reset()

        XCTAssertFalse(store.hasTenantFiles())
        XCTAssertFalse(store.hasTenantFile(id: "file-1"))
        XCTAssertFalse(store.isTenantFilesSyncing())
        XCTAssertNil(store.tenantFilesSyncError())
    }

    func testAppStateIgnoresSearchInvalidationFromDifferentTenant() {
        var context = makeIsolatedAPIContext()
        context.tenantID = "tenant-current"
        let state = AppState(apiContextOverride: context)
        state.files = [
            FileItem(
                id: "file-1",
                name: "report.pdf",
                type: "PDF",
                size: "2 KB",
                owner: "Mia",
                source: "企业文件",
                time: "10:00",
                scope: "企业文件",
                status: "已上传",
                accentHex: 0x6677FF
            )
        ]
        let initialRevision = state.searchInvalidationRevision

        state.applySearchInvalidation(SearchInvalidationEvent(
            tenantID: "tenant-other",
            invalidationKey: "file:file-1",
            eventType: "file_deleted",
            reason: "deleted",
            fileID: "file-1",
            version: 1
        ))

        XCTAssertEqual(state.searchInvalidationRevision, initialRevision)
        XCTAssertNil(state.latestSearchInvalidation)
        XCTAssertEqual(state.files.map(\.id), ["file-1"])

        state.applySearchInvalidation(SearchInvalidationEvent(
            tenantID: "tenant-current",
            invalidationKey: "file:file-1",
            eventType: "file_deleted",
            reason: "deleted",
            fileID: "file-1",
            version: 1
        ))

        XCTAssertEqual(state.searchInvalidationRevision, initialRevision + 1)
        XCTAssertEqual(state.latestSearchInvalidation?.tenantID, "tenant-current")
        XCTAssertTrue(state.files.isEmpty)
    }

    func testFileStoreUploadConfigLifecycleResetsToDefault() throws {
        let store = FileStore()
        let config = FileUploadConfig(
            maxBytes: 8 * 1024 * 1024,
            maxMB: 8,
            source: "tenant",
            messageRecallMaxMinutes: 15,
            voiceCallEnabled: false,
            videoCallEnabled: false,
            readReceiptsEnabled: false,
            groupAdminDeleteMessageEnabled: true
        )

        XCTAssertEqual(store.currentUploadConfig(), .defaultValue)
        XCTAssertTrue(store.currentUploadConfig().voiceCallEnabled)
        XCTAssertFalse(store.currentUploadConfig().videoCallEnabled)

        store.replaceUploadConfig(config)

        XCTAssertEqual(store.currentUploadConfig(), config)

        store.reset()

        XCTAssertEqual(store.currentUploadConfig(), .defaultValue)
    }

    func testDefaultFileUploadLimitAllowsExactly500MiBAndRejectsOneByteMore() {
        let config = FileUploadConfig.defaultValue
        let exactLimit = Int64(500 * 1024 * 1024)

        XCTAssertEqual(config.maxBytes, exactLimit)
        XCTAssertEqual(config.maxMB, 500)
        XCTAssertTrue(config.allowsUpload(sizeBytes: exactLimit))
        XCTAssertFalse(config.allowsUpload(sizeBytes: exactLimit + 1))
    }

    func testPendingAttachmentManagedFileSurvivesRetryAndIsRemovedOnCancel() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-upload-source-\(UUID().uuidString).gif")
        try Data("GIF89a".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try PendingAttachmentFileStore.stageFile(
            from: source,
            preferredName: "animated.gif"
        )
        let store = FileStore()
        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .image,
            name: "animated.gif",
            mimeType: "image/gif",
            sizeBytes: staged.sizeBytes,
            fileURL: staged.url,
            removeFileWhenFinished: true,
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-file-upload")

        store.finishAttachmentUploadTask(messageID: "local-file-upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        store.cancelAttachmentUpload(messageID: "local-file-upload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testFileStoreCancelAttachmentDownloadTasksClearsDownloadsOnly() throws {
        let store = FileStore()
        let downloadTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            downloadTask.cancel()
            uploadTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: downloadTask)
        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.cancelAttachmentDownloadTasks()

        XCTAssertTrue(downloadTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertFalse(uploadTask.isCancelled)
        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertTrue(store.hasAttachmentUploadTask(messageID: "local-upload-1"))
    }

    func testFileStoreAttachmentDownloadTaskLifecycleReplacesCancelsAndFinishes() throws {
        let store = FileStore()
        let firstTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        let secondTask = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return FileManager.default.temporaryDirectory
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: firstTask)

        XCTAssertTrue(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
        XCTAssertNotNil(store.attachmentDownloadTask(attachmentID: "file-1"))

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: secondTask)

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertNotNil(store.attachmentDownloadTask(attachmentID: "file-1"))

        store.finishAttachmentDownloadTask(attachmentID: "file-1")

        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))

        store.replaceAttachmentDownloadTask(attachmentID: "file-1", with: secondTask)
        store.cancelAttachmentDownloadTask(attachmentID: "file-1")

        XCTAssertTrue(secondTask.isCancelled)
        XCTAssertFalse(store.hasAttachmentDownloadTask(attachmentID: "file-1"))
    }

    func testFileStoreAttachmentDownloadProgressAndFailedStateLifecycle() throws {
        let store = FileStore()

        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))

        store.setAttachmentDownloadProgress(0.42, attachmentID: "file-1")
        store.setAttachmentDownloadProgress(0.7, attachmentID: "file-2")
        store.markAttachmentDownloadFailed(attachmentID: "file-1")

        XCTAssertEqual(try XCTUnwrap(store.attachmentDownloadProgress(attachmentID: "file-1")), 0.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.attachmentDownloadProgress(attachmentID: "file-2")), 0.7, accuracy: 0.001)
        XCTAssertTrue(store.isAttachmentDownloadFailed(attachmentID: "file-1"))

        store.clearAttachmentDownloadProgress(attachmentIDs: ["file-1", "file-2"])
        store.clearAttachmentDownloadFailed(attachmentID: "file-1")

        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-1"))
        XCTAssertNil(store.attachmentDownloadProgress(attachmentID: "file-2"))
        XCTAssertFalse(store.isAttachmentDownloadFailed(attachmentID: "file-1"))
    }

    func testFileStoreAttachmentUploadTaskLifecycleReplacesCancelsAndFinishes() throws {
        let store = FileStore()
        let firstTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let secondTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")

        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertTrue(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))

        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: firstTask)
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: secondTask)

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertTrue(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))

        store.finishAttachmentUploadTask(messageID: "local-upload-1")

        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertTrue(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))

        store.finishAttachmentUpload(messageID: "local-upload-1")

        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testFileStoreCancelAttachmentUploadClearsPendingAndCancelsTask() throws {
        let store = FileStore()
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            uploadTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .image,
            name: "photo.jpg",
            mimeType: "image/jpeg",
            sizeBytes: 5,
            data: Data("image".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.cancelAttachmentUpload(messageID: "local-upload-1")

        XCTAssertTrue(uploadTask.isCancelled)
        XCTAssertFalse(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testFileStoreResetClearsAttachmentUploadRuntimeStateAndCancelsTasks() throws {
        let store = FileStore()
        let uploadTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            uploadTask.cancel()
        }

        store.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .file,
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 7,
            data: Data("payload".utf8),
            conversationID: "conversation-1",
            quote: nil,
            replyContext: nil
        ), messageID: "local-upload-1")
        store.replaceAttachmentUploadTask(messageID: "local-upload-1", with: uploadTask)

        store.reset()

        XCTAssertTrue(uploadTask.isCancelled)
        XCTAssertFalse(store.hasPendingAttachmentUpload(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadTask(messageID: "local-upload-1"))
        XCTAssertFalse(store.hasAttachmentUploadRuntimeState(messageID: "local-upload-1"))
    }

    func testToastDismissTaskStoreReplacesAndCancelsTasks() throws {
        let store = ToastDismissTaskStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
        }

        store.replace(with: first)
        XCTAssertTrue(store.hasTask)

        store.replace(with: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasTask)

        store.cancel()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasTask)
    }

    func testLaunchSplashDismissTaskStoreReplacesAndCancelsTasks() throws {
        let store = LaunchSplashDismissTaskStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
        }

        store.replace(with: first)
        XCTAssertTrue(store.hasTask)

        store.replace(with: second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasTask)

        store.cancel()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasTask)
    }

    func testCallStoreVoiceCallWatchdogTaskLifecycleCancelsAndResetClears() throws {
        let store = CallStore()
        let first = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let second = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let third = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        defer {
            first.cancel()
            second.cancel()
            third.cancel()
        }

        store.replaceVoiceCallWatchdogTask(first)
        XCTAssertTrue(store.hasVoiceCallWatchdogTask)

        store.replaceVoiceCallWatchdogTask(second)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(store.hasVoiceCallWatchdogTask)

        store.cancelVoiceCallWatchdogTask()
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(store.hasVoiceCallWatchdogTask)

        store.replaceVoiceCallWatchdogTask(third)
        store.reset()
        XCTAssertTrue(third.isCancelled)
        XCTAssertFalse(store.hasVoiceCallWatchdogTask)
    }

    func testCallStorePersistsCallRecordsByScopeAndResetKeepsCache() throws {
        let suiteName = "CallStorePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.test"
        )
        let scope = "tenant-a|uid-a"
        let otherScope = "tenant-b|uid-b"
        let record = CallRecord(
            id: "record-a",
            callID: "call-a",
            peerID: "peer-a",
            peerUserID: "public-a",
            peerAvatarURL: "https://example.com/avatar-a.png",
            peerAvatarVersion: "avatar-v1",
            peerAvatarUpdatedAt: "2026-08-22T10:00:00Z",
            peerAvatarSource: "rtc_profile",
            title: "Alice",
            subtitle: "视频呼出 · 通话已结束",
            time: "10:00",
            status: "已结束",
            direction: .outgoing,
            callType: "视频通话",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 130),
            durationSeconds: 30,
            endReason: "remote_hangup",
            stateVersion: 9
        )

        let store = CallStore(callRecordStore: backingStore)
        store.bindCallRecordPersistence(scope: scope)
        store.calls = [record]

        store.reset()
        XCTAssertTrue(store.calls.isEmpty)
        let cachedRecord = try XCTUnwrap(backingStore.load(scope: scope).first)
        XCTAssertEqual(cachedRecord.callID, "call-a")
        XCTAssertEqual(cachedRecord.peerID, "peer-a")
        XCTAssertEqual(cachedRecord.peerUserID, "public-a")
        XCTAssertEqual(cachedRecord.peerAvatarURL, "https://example.com/avatar-a.png")
        XCTAssertEqual(cachedRecord.peerAvatarVersion, "avatar-v1")
        XCTAssertEqual(cachedRecord.peerAvatarUpdatedAt, "2026-08-22T10:00:00Z")
        XCTAssertEqual(cachedRecord.peerAvatarSource, "rtc_profile")
        XCTAssertEqual(cachedRecord.callType, "视频通话")
        XCTAssertEqual(cachedRecord.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(cachedRecord.endedAt, Date(timeIntervalSince1970: 130))
        XCTAssertEqual(cachedRecord.durationSeconds, 30)
        XCTAssertEqual(cachedRecord.endReason, "remote_hangup")
        XCTAssertEqual(cachedRecord.stateVersion, 9)

        let relaunchedStore = CallStore(callRecordStore: backingStore)
        relaunchedStore.bindCallRecordPersistence(scope: scope)
        let relaunchedRecord = try XCTUnwrap(relaunchedStore.calls.first)
        XCTAssertEqual(relaunchedRecord.callID, "call-a")
        XCTAssertEqual(relaunchedRecord.peerID, "peer-a")
        XCTAssertEqual(relaunchedRecord.peerUserID, "public-a")
        XCTAssertEqual(relaunchedRecord.callType, "视频通话")
        XCTAssertEqual(relaunchedRecord.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(relaunchedRecord.endedAt, Date(timeIntervalSince1970: 130))
        XCTAssertEqual(relaunchedRecord.durationSeconds, 30)
        XCTAssertEqual(relaunchedRecord.endReason, "remote_hangup")
        XCTAssertEqual(relaunchedRecord.stateVersion, 9)

        let otherStore = CallStore(callRecordStore: backingStore)
        otherStore.bindCallRecordPersistence(scope: otherScope)
        XCTAssertTrue(otherStore.calls.isEmpty)
    }

    func testCallStoreMigratesCallRecordsFromFallbackScope() throws {
        let suiteName = "CallStoreFallbackMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.fallback.test"
        )
        let stableScope = "call-records|tenant-a|uid-a"
        let legacyDeviceScope = "v2|account=account-a|tenant=tenant-a|im=uid-a|app=app-a|device=device-a"
        let record = CallRecord(
            id: "legacy-record",
            callID: "legacy-call",
            peerID: "peer-a",
            title: "Alice",
            subtitle: "视频来电 · 通话已结束",
            time: "11:00",
            status: "已结束",
            direction: .incoming,
            callType: "视频通话",
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 260),
            durationSeconds: 60
        )
        backingStore.save([record], scope: legacyDeviceScope)
        XCTAssertTrue(backingStore.load(scope: stableScope).isEmpty)

        let store = CallStore(callRecordStore: backingStore)
        store.bindCallRecordPersistence(scope: stableScope, fallbackScopes: [legacyDeviceScope])

        XCTAssertEqual(store.calls.first?.callID, "legacy-call")
        XCTAssertEqual(store.calls.first?.callType, "视频通话")
        XCTAssertEqual(backingStore.load(scope: stableScope).first?.callID, "legacy-call")
        XCTAssertEqual(backingStore.load(scope: legacyDeviceScope).first?.callID, "legacy-call")
    }

    func testCallStoreKeepsAccountHistoryIsolatedAndPreservesUntrustedArchive() throws {
        let suiteName = "CallStoreAccountScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backingStore = UserDefaultsCallRecordStore(defaults: defaults, storageKey: "call.records.account.test")
        let accountA = "v3|bundle=app1|app=main|account=a|tenant=t|im=u1"
        let accountB = "v3|bundle=app1|app=main|account=b|tenant=t|im=u2"
        let contaminatedAccountB = "v2|bundle=app1|app=main|account=b|tenant=t|im=u2"
        let sharedScope = "v2|bundle=app1|app=main"
        let record = CallRecord(id: "a-record", callID: "a-call", peerID: "peer-a",
                                title: "Fixture A", subtitle: "已结束", time: "12:30", status: "已结束")
        backingStore.save([record], scope: sharedScope)
        backingStore.save([record], scope: contaminatedAccountB)
        let store = CallStore(callRecordStore: backingStore)
        store.bindCallRecordPersistence(scope: accountA)
        store.calls = [record]
        store.clearCallRecordPersistenceBinding()
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertEqual(backingStore.load(scope: accountA), [record])
        store.bindCallRecordPersistence(scope: accountB)
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertTrue(backingStore.load(scope: accountB).isEmpty)
        let ownRecord = CallRecord(id: "b-record", callID: "b-call", peerID: "peer-b",
                                   title: "Fixture B", subtitle: "已结束", time: "12:35", status: "已结束")
        store.calls = [ownRecord]
        store.bindCallRecordPersistence(scope: accountA)
        XCTAssertEqual(store.calls, [record])
        let relaunched = CallStore(callRecordStore: backingStore)
        relaunched.bindCallRecordPersistence(scope: accountB)
        XCTAssertEqual(relaunched.calls, [ownRecord])
        XCTAssertEqual(backingStore.load(scope: sharedScope), [record])
        XCTAssertEqual(backingStore.load(scope: contaminatedAccountB), [record])
    }

    func testAccountContextChangeImmediatelyDetachesPreviousCallHistory() {
        var contextA = makeIsolatedAPIContext()
        contextA.accountID = "call-isolation-account-a"
        contextA.tenantID = "call-isolation-tenant"
        contextA.imUID = "call-isolation-uid-a"
        contextA.imToken = "fixture-token-a"
        let state = AppState(apiContextOverride: contextA)
        state.callStore.calls = [CallRecord(id: "a-record", title: "Fixture A",
                                           subtitle: "已结束", time: "12:30", status: "已结束")]
        var contextB = contextA
        contextB.accountID = "account-b"
        contextB.imUID = "uid-b"
        contextB.imToken = "fixture-token-b"
        state.overrideAPIContextForTesting(contextB)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
    }

    func testCallRecordStoreRestoresFromDiskWhenDefaultsAreCleared() throws {
        let suiteName = "CallRecordDiskPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-records-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        let scope = "bundle=app1|tenant=a|uid=u"
        let record = CallRecord(
            id: "disk-record",
            callID: "disk-call",
            peerID: "peer-disk",
            title: "Alice",
            subtitle: "语音呼出 · 通话已结束",
            time: "12:00",
            status: "已结束",
            direction: .outgoing,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 330),
            durationSeconds: 30
        )
        let store = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.disk.test",
            archiveURL: archiveURL
        )
        store.save([record], scope: scope)
        XCTAssertEqual(store.load(scope: scope).first?.callID, "disk-call")

        defaults.removePersistentDomain(forName: suiteName)
        let relaunchedStore = UserDefaultsCallRecordStore(
            defaults: defaults,
            storageKey: "call.records.disk.test",
            archiveURL: archiveURL
        )

        let relaunchedRecord = try XCTUnwrap(relaunchedStore.load(scope: scope).first)
        XCTAssertEqual(relaunchedRecord.callID, "disk-call")
        XCTAssertEqual(relaunchedRecord.peerID, "peer-disk")
        XCTAssertEqual(relaunchedRecord.startedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(relaunchedRecord.endedAt, Date(timeIntervalSince1970: 330))
        XCTAssertEqual(relaunchedRecord.durationSeconds, 30)
    }

    @MainActor
    func testAppStateVoiceCallRequiresFriendRelationship() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")
        let stranger = makeUser(id: "stranger-1", name: "Stranger")

        state.currentUser = currentUser
        state.contacts = [friend]

        // This test exercises relationship/media availability, not unknown license authority.
        state.overrideAPIContextForTesting(makeAuthenticatedAPIContext())
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)

        XCTAssertFalse(state.canStartVoiceCall(with: friend))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: friend), "当前 iOS 版本暂未接入真实语音媒体，暂不能使用语音通话")
        XCTAssertFalse(state.canStartVoiceCall(with: stranger))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: stranger), "需先添加好友后才能发起语音通话")

        state.startOutgoingVoiceCall(to: friend)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "当前 iOS 版本暂未接入真实语音媒体，暂不能使用语音通话")

        state.startOutgoingVoiceCall(to: stranger)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "需先添加好友后才能发起语音通话")
    }

    @MainActor
    func testDirectCallLicenseMatrixKeepsVoiceAndVideoIndependentAndBlocksVoiceBeforeNetwork() throws {
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-call-license", name: "Call Peer")
        state.isAuthenticated = true
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true

        let matrix: [(voice: Bool, video: Bool)] = [
            (true, false),
            (true, true),
            (false, false),
            (false, true)
        ]
        for row in matrix {
            state.fileUploadConfig = callLicenseFileConfig(
                voiceEnabled: row.voice,
                videoEnabled: row.video
            )

            XCTAssertEqual(state.isVoiceCallLicensedForCurrentTenant, row.voice)
            XCTAssertEqual(state.isVideoCallLicensedForCurrentTenant, row.video)
            state.rtcCapabilityAlertMessage = nil
            XCTAssertEqual(state.guardCallLicenseForAction(.voice), row.voice)
            XCTAssertEqual(state.rtcCapabilityAlertMessage, row.voice ? nil : "该企业未开通语音通话")
            state.rtcCapabilityAlertMessage = nil
            XCTAssertEqual(state.guardCallLicenseForAction(.video), row.video)
            XCTAssertEqual(state.rtcCapabilityAlertMessage, row.video ? nil : "该企业未开通视频通话")
            XCTAssertTrue(state.canStartVoiceCall(with: peer))
            XCTAssertEqual(state.videoCallUnavailableReason(for: peer) == nil, row.video)

            XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
            if !row.voice {
                state.toast = nil
                state.startOutgoingVoiceCall(to: peer, channelID: "uid-1:peer-call-license")
                XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
                XCTAssertFalse(state.isStartingVoiceCall)
                XCTAssertNil(state.activeVoiceCall)
            }
        }

        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
    }

    @MainActor
    func testDirectCallLicenseCapabilitiesFailClosedAfterTenantSwitchUntilCurrentConfigArrives() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-tenant-switch", name: "Peer")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)

        XCTAssertTrue(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertTrue(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertNil(state.videoCallUnavailableReason(for: peer))

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-2"
        switchedContext.imUID = "uid-2"
        switchedContext.imToken = "im-token-2"
        state.overrideAPIContextForTesting(switchedContext)

        XCTAssertFalse(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertFalse(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertEqual(state.videoCallUnavailableReason(for: peer), "暂时无法确认视频通话权限，请稍后重试")
        state.startOutgoingVoiceCall(to: peer)
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试")
        XCTAssertFalse(state.isStartingVoiceCall)

        state.toast = nil
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-voice-old-tenant",
            callID: "incoming-voice-old-tenant",
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.acceptIncomingVoiceCall()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试")
        XCTAssertNil(state.activeVoiceCall)
        state.incomingVoiceCall = nil

        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)

        XCTAssertFalse(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertTrue(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertNil(state.videoCallUnavailableReason(for: peer))
    }

    @MainActor
    func testIncomingVideoAcceptFailsClosedForRevokedLicenseAndStalePermissionCallback() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-video-license",
            callID: "incoming-video-stale",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )
        state.incomingVoiceCall = incoming
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )

        state.acceptIncomingVideoCall(as: "video")

        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通视频通话")
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-stale/accept"),
            0
        )

        state.toast = nil
        state.incomingVoiceCall = incoming
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.acceptIncomingVideoCall(as: "audio")

        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let microphoneDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(microphoneDecisionIsWaiting)

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-after-permission"
        switchedContext.imUID = "uid-after-permission"
        switchedContext.imToken = "im-token-after-permission"
        state.overrideAPIContextForTesting(switchedContext)
        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-stale/accept"),
            0
        )
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCLicenseMissingFieldsStayUnknownWithoutDisablingTheOtherKnownMedia() throws {
        let cases: [(String, Bool, Bool)] = [
            (#"{}"#, false, false),
            (#"{"voice_call_enabled":null,"video_call_enabled":"invalid"}"#, false, false),
            (#"{"voice_message":true,"video_message":true}"#, false, false),
            (#"{"voice_call_enabled":false}"#, true, false),
            (#"{"features":{"video_call_enabled":true}}"#, false, true),
            (#"{"features":{"voice_call_enabled":false,"video_call_enabled":true}}"#, true, true)
        ]
        for (json, voiceKnown, videoKnown) in cases {
            let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data(json.utf8)).model
            XCTAssertEqual(config.voiceCallLicenseKnown, voiceKnown, json)
            XCTAssertEqual(config.videoCallLicenseKnown, videoKnown, json)
            let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
            state.fileUploadConfig = config
            if !voiceKnown {
                XCTAssertEqual(state.callLicenseUnavailableMessage(for: .voice), "暂时无法确认语音通话权限，请稍后重试")
            }
            if !videoKnown {
                XCTAssertEqual(state.callLicenseUnavailableMessage(for: .video), "暂时无法确认视频通话权限，请稍后重试")
            }
        }
        XCTAssertFalse(FileUploadConfig.defaultValue.voiceCallLicenseKnown)
        XCTAssertFalse(FileUploadConfig.defaultValue.videoCallLicenseKnown)
    }

    func testRTCLicenseScopeChangesAndABACannotRestoreAuthorityWithoutFreshConfig() {
        let original = makeAuthenticatedAPIContext()
        let mutations: [(inout IMAPIContext) -> Void] = [
            { $0.tenantID = "tenant-other" },
            { $0.accountID = "account-other" },
            { $0.imUID = "uid-other" },
            { $0.deviceID = "device-other" },
            { $0.appID = "other-ios-app" },
            { $0.imToken = "replacement-test-session" }
        ]
        for mutate in mutations {
            let state = AppState(apiContextOverride: original)
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            XCTAssertTrue(state.guardCallLicenseForAction(.voice))
            var changed = original
            mutate(&changed)
            state.overrideAPIContextForTesting(changed)
            XCTAssertFalse(state.guardCallLicenseForAction(.voice))
            XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试")
            state.overrideAPIContextForTesting(original)
            XCTAssertFalse(state.guardCallLicenseForAction(.video), "Returning to the same scope must not resurrect stale authority")
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            XCTAssertFalse(state.guardCallLicenseForAction(.voice))
            XCTAssertTrue(state.guardCallLicenseForAction(.video))
        }
        let loggedOut = AppState(apiContextOverride: makeIsolatedAPIContext())
        loggedOut.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        XCTAssertFalse(loggedOut.guardCallLicenseForAction(.voice))
        XCTAssertFalse(loggedOut.guardCallLicenseForAction(.video))
    }

    func testRTCLicenseRepeatedDeniedAndUnknownActionsHaveZeroMediaAndCallSideEffects() async {
        for unknown in [false, true] {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let video = TestVideoMediaClient()
            let voice = TestVoiceMediaClient()
            var microphoneRequests = 0
            var videoPermissionRequests = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: voice,
                videoMediaClient: video,
                microphonePermissionDecisionOverride: { microphoneRequests += 1; return true },
                videoPermissionDecisionOverride: { videoPermissionRequests += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            let peer = makeUser(id: "license-denied-peer", name: "Peer")
            state.currentUser = makeUser(id: "uid-1", name: "Me")
            state.contacts = [peer]
            state.fileUploadConfig = unknown ? .defaultValue : callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
            let initialRecords = state.calls.count
            for _ in 0..<3 {
                state.rtcCapabilityAlertMessage = nil
                state.startOutgoingVoiceCall(to: peer)
                XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认语音通话权限，请稍后重试" : "该企业未开通语音通话")
                state.startOutgoingVideoCall(to: peer)
                XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认视频通话权限，请稍后重试" : "该企业未开通视频通话")
                for type in [RTCCallRecordType.audio, .video] {
                    state.rtcCapabilityAlertMessage = nil
                    let record = RTCCallRecordPayload(
                        schemaVersion: 1, callID: "historical-license", callType: type,
                        callerUID: "uid-1", calleeUID: peer.id, finalOutcome: .noAnswer,
                        startedAt: Date(), answeredAt: nil, mediaConnectedAt: nil,
                        endedAt: Date(), durationSeconds: 0, reasonCode: "no_answer",
                        fallbackText: "", endActorUID: nil, finalMediaMode: nil
                    )
                    state.redialRTCCallRecord(record, viewerIsCaller: true, conversationID: "license-conversation")
                    let media = type == .audio ? "语音通话" : "视频通话"
                    XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认\(media)权限，请稍后重试" : "该企业未开通\(media)")
                }
                state.presentVideoCallPreview(to: peer)
                XCTAssertNil(state.videoCallPreview)
                state.incomingVoiceCall = IncomingVoiceCall(id: "license-incoming", callID: "license-incoming", caller: peer, startedAt: "刚刚", source: "好友语音通话")
                state.acceptIncomingVoiceCall()
                state.incomingVoiceCall = IncomingVoiceCall(id: "license-incoming", callID: "license-incoming", caller: peer, startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
                state.acceptIncomingVideoCall(as: "video")
                state.incomingVoiceCall = nil
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(microphoneRequests, 0)
            XCTAssertEqual(videoPermissionRequests, 0)
            XCTAssertEqual(video.startCount, 0)
            XCTAssertTrue(voice.startedContexts.isEmpty)
            XCTAssertTrue(video.cameraValues.isEmpty)
            XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/license-incoming/accept"), 0)
            XCTAssertEqual(state.calls.count, initialRecords)
            XCTAssertNil(state.activeVoiceCall)
            XCTAssertFalse(state.isStartingVoiceCall)
            XCTAssertFalse(state.isStartingVideoCall)
        }
    }

    func testRTCVideoOnlyLicenseAllowsVideoButBlocksExplicitAudioAnswerBeforePermission() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, voiceEnabled: false)
        let permission = SuspendedBoolDecision()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { await permission.wait() },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "video-only", callID: "video-only", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
        state.acceptIncomingVideoCall(as: "audio")
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
        let blockedPermission = await permission.isWaiting()
        XCTAssertFalse(blockedPermission)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)

        state.rtcCapabilityAlertMessage = nil
        state.acceptIncomingVideoCall(as: "video")
        for _ in 0..<200 {
            if await permission.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let allowedPermission = await permission.isWaiting()
        XCTAssertTrue(allowedPermission, "Video permission proceeds independently of disabled voice calls")
        XCTAssertNil(state.rtcCapabilityAlertMessage)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 1)
        // End the test before camera/media activation; this is not a real call.
        await permission.resume(returning: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-only/accept"), 0)
    }

    func testRTCFreshProviderRefusalShowsTypedLicenseModalBeforePermissions() async {
        let cases = [(403, "voice_call_not_enabled", "该企业未开通语音通话"),
                     (503, "rtc_license_capabilities_unavailable", "暂时无法确认语音通话权限，请稍后重试")]
        for (status, code, message) in cases {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: status, providerErrorCode: code)
            var permissionRequests = 0
            let voice = TestVoiceMediaClient()
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: voice,
                microphonePermissionDecisionOverride: { permissionRequests += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: "provider-refusal", callID: "provider-refusal", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
            state.acceptIncomingVoiceCall()
            for _ in 0..<200 {
                if state.rtcCapabilityAlertMessage != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(state.rtcCapabilityAlertMessage, message)
            XCTAssertEqual(permissionRequests, 0)
            XCTAssertTrue(voice.startedContexts.isEmpty)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/provider-refusal/accept"), 0)
            XCTAssertNil(state.activeVoiceCall)
        }
    }

    func testRTCFreshFileConfigFailureBecomesUnknownBeforeVideoPermission() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, fileConfigStatusCode: 503)
        var permissionRequests = 0
        let video = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: video,
            microphonePermissionDecisionOverride: { permissionRequests += 1; return true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "config-failure", callID: "config-failure", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
        state.acceptIncomingVideoCall(as: "video")
        for _ in 0..<200 {
            if state.rtcCapabilityAlertMessage != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认视频通话权限，请稍后重试")
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(video.startCount, 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/config-failure/accept"), 0)
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCLateConfigResponseAcrossScopeABACannotOverwriteCurrentDenial() async {
        let gate = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, fileConfigDecision: gate)
        var permissions = 0
        let original = makeAuthenticatedAPIContext()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            microphonePermissionDecisionOverride: { permissions += 1; return true },
            apiContextOverride: original
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "config-aba", callID: "config-aba", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let isWaiting = await gate.isWaiting()
        XCTAssertTrue(isWaiting)
        var other = original
        other.tenantID = "tenant-config-aba"
        state.overrideAPIContextForTesting(other)
        state.overrideAPIContextForTesting(original)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
        let voiceGeneration = state.callLicenseActionGeneration(for: .voice)
        await gate.resume(returning: true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(state.callLicenseActionGeneration(for: .voice), voiceGeneration)
        XCTAssertEqual(state.callLicenseUnavailableMessage(for: .voice), "该企业未开通语音通话")
        XCTAssertEqual(state.callLicenseUnavailableMessage(for: .video), "该企业未开通视频通话")
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/config-aba/accept"), 0)
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCProviderMissingLicenseAndNetworkFailureRemainUnknownBeforeMedia() async {
        for networkFailure in [false, true] {
            for media in [RTCCapabilityMedia.voice, .video] {
                let transport = VideoCallStartHTTPTransport(
                    fileConfigDelayNanoseconds: 0, providerStatusCode: 200,
                    providerOmitsLicense: !networkFailure, providerNetworkFailure: networkFailure
                )
                var permissions = 0
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport),
                    videoMediaClient: TestVideoMediaClient(),
                    microphonePermissionDecisionOverride: { permissions += 1; return true },
                    apiContextOverride: makeAuthenticatedAPIContext()
                )
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(id: "provider-unknown", callID: "provider-unknown", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友通话", requestedMediaMode: media == .video ? "video" : "audio")
                if media == .video {
                    state.acceptIncomingVideoCall(as: "video")
                } else {
                    state.acceptIncomingVoiceCall()
                }
                for _ in 0..<200 {
                    if state.rtcCapabilityAlertMessage != nil { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let name = media == .video ? "视频通话" : "语音通话"
                XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认\(name)权限，请稍后重试")
                XCTAssertEqual(permissions, 0)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/provider-unknown/accept"), 0)
                XCTAssertNil(state.activeVoiceCall)
            }
        }
    }

    func testRTCLicenseRevocationKeepsEstablishedCallAndBlocksNewMediaModeActions() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let video = TestVideoMediaClient()
        let state = AppState(api: makeCallEndingAPI(transport: transport), videoMediaClient: video, apiContextOverride: makeAuthenticatedAPIContext())
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        var connected = makeRTCMediaHeartbeatVideoCall(callID: "established-license")
        connected.mediaState = .connected
        connected.statusText = "通话中"
        connected.connectedAt = Date()
        state.activeVoiceCall = connected

        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
        XCTAssertEqual(state.activeVoiceCall?.callID, "established-license")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        state.downgradeActiveVideoCallToAudio()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "video")

        connected.mediaMode = "audio"
        state.activeVoiceCall = connected
        state.requestActiveAudioCallVideoUpgrade()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通视频通话")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.callID, "established-license")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(video.downgradeToAudioCount, 0)
        XCTAssertTrue(video.stopReasons.isEmpty)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/established-license/downgrade"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/established-license/hangup"), 0)
    }

    @MainActor
    func testIncomingVoiceAnswerCoalescesTapsAndPermissionDenialReenablesSameCall() async throws {
        let permissionDecision = SuspendedBoolDecision()
        var permissionRequests = 0
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                permissionRequests += 1
                return await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-repeat-answer", callID: "incoming-repeat-answer",
            caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话"
        )

        state.acceptIncomingVoiceCall()
        XCTAssertEqual(state.incomingCallAnswerMode, "audio")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(permissionRequests, 1, "repeated taps must share the first answer attempt")
        await permissionDecision.resume(returning: false)
        for _ in 0..<200 where state.incomingCallAnswerMode != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertEqual(state.incomingVoiceCall?.id, "incoming-repeat-answer")
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/incoming-repeat-answer/accept"), 0)
    }

    @MainActor
    func testIncomingAnswerStatePreservesRefreshAndClearsOnReplacementOrTermination() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        var incoming = IncomingVoiceCall(
            id: "first-presentation", callID: "first-call",
            caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话"
        )
        state.incomingVoiceCall = incoming
        state.incomingCallAnswerMode = "audio"
        let answerOperation = UUID()
        state.callStore.incomingCallAnswerOperationID = answerOperation
        incoming.caller = makeUser(id: "peer", name: "Updated Peer")
        incoming.stateVersion = 2
        state.incomingVoiceCall = incoming
        XCTAssertEqual(state.incomingCallAnswerMode, "audio", "profile refresh must not unlock another answer")
        XCTAssertEqual(state.callStore.incomingCallAnswerOperationID, answerOperation)

        let replacement = IncomingVoiceCall(
            id: "next-presentation", callID: "next-call", caller: incoming.caller,
            startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video"
        )
        state.incomingVoiceCall = replacement
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertNil(state.callStore.incomingCallAnswerOperationID)
        state.incomingCallAnswerMode = "video"
        state.incomingVoiceCall = nil
        XCTAssertNil(state.incomingCallAnswerMode)
        state.callStore.incomingCallAnswerMode = "audio"
        state.callStore.incomingCallAnswerOperationID = UUID()
        state.callStore.reset()
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertNil(state.callStore.incomingCallAnswerOperationID)
    }

    @MainActor
    func testIncomingVoiceAcceptFailsClosedWhenLicenseIsRevokedDuringMicrophonePermission() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-voice-license-revoked",
            callID: "incoming-voice-license-revoked",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let microphoneDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(microphoneDecisionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: false,
            videoEnabled: true
        )
        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-license-revoked/accept"),
            0
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    @MainActor
    func testIncomingVoiceAcceptAttemptCannotReviveAcrossSameScopeLicenseABA() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-license-aba",
            callID: "incoming-voice-license-aba",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let abaPermissionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(abaPermissionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: false,
            videoEnabled: true
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        await permissionDecision.resume(returning: true)
        for _ in 0..<30 {
            await Task.yield()
        }

        XCTAssertEqual(state.incomingVoiceCall?.id, incoming.id)
        XCTAssertEqual(state.incomingVoiceCall?.callID, incoming.callID)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-license-aba/accept"),
            0
        )
    }

    @MainActor
    func testIncomingVoiceOldPermissionCallbackCannotOwnSameScopeReplacementSession() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-session-replaced",
            callID: "incoming-voice-session-replaced",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let replacementPermissionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(replacementPermissionIsWaiting)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        await permissionDecision.resume(returning: true)
        for _ in 0..<30 {
            await Task.yield()
        }

        XCTAssertEqual(state.incomingVoiceCall?.id, incoming.id)
        XCTAssertEqual(state.incomingVoiceCall?.callID, incoming.callID)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-session-replaced/accept"),
            0
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    @MainActor
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: accepted callee appID may be missing on Android; device remains authoritative.
    func testOutgoingV1RequiresAuthoritativeWinningDevice() throws {
        func snapshot(status: String = "accepted", app: String = "callee-app", device: String = "winner", version: Int64 = 2) -> RemoteRTCCall {
            RemoteRTCCall(id: "call", status: status, roomID: "room", callerUID: "caller", calleeUID: "callee",
                callerDevice: RemoteRTCDevice(uid: "caller", deviceID: "self-device", appID: "caller-app"),
                acceptedDevice: RemoteRTCDevice(uid: "callee", deviceID: device, appID: app), stateVersion: version)
        }
        func permits(_ call: RemoteRTCCall?, localApp: String = "caller-app", localDevice: String = "self-device", id: String = "call", room: String = "room") -> Bool {
            AppState.hasBoundAcceptedOutgoingCall(call, callID: id, roomID: room,
                callerUID: "caller", callerDeviceID: localDevice, callerAppID: localApp,
                calleeUID: "callee", minimumStateVersion: 2)
        }
        XCTAssertTrue(permits(snapshot()))
        XCTAssertFalse(permits(nil))
        for status in ["ringing", "canceled", "ended", "timed_out", "rejected"] { XCTAssertFalse(permits(snapshot(status: status))) }
        XCTAssertTrue(permits(snapshot(app: "")))
        XCTAssertFalse(permits(snapshot(device: "")))
        XCTAssertFalse(permits(snapshot(version: 1)))
        XCTAssertFalse(permits(snapshot(), localApp: "another-app"))
        XCTAssertFalse(permits(snapshot(), localDevice: "another-device"))
        XCTAssertFalse(permits(snapshot(), id: "later-call"))
        XCTAssertFalse(permits(snapshot(), room: "later-room"))
        let decoded = try JSONDecoder().decode(RemoteRTCDevice.self,
            from: Data(#"{"uid":"callee","device_id":"winner","app_id":"callee-app"}"#.utf8))
        XCTAssertEqual(decoded.appID, "callee-app")
        XCTAssertTrue(AppState.isRTCTransportPolicyPending(IMAPIError.conflict(code: "rtc_transport_policy_pending", message: "pending")))
        XCTAssertFalse(AppState.isRTCTransportPolicyPending(IMAPIError.conflict(code: "callee_busy", message: "busy")))
        XCTAssertFalse(AppState.isRTCTransportPolicyPending(CancellationError()))
    }
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END

    @MainActor
    func testOutgoingV1AudioAndVideoWaitWithoutJoinAndDoNotCancelPendingAcceptance() async throws {
        for video in [false, true] {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, outgoingPolicyFixture: true)
            let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, httpTransport: transport)
            let state = AppState(api: api, voiceMediaClient: TestVoiceMediaClient(events: []),
                videoMediaClient: TestVideoMediaClient(), microphonePermissionDecisionOverride: { true },
                apiContextOverride: makeAuthenticatedAPIContext())
            let peer = makeUser(id: "policy-peer", name: "Peer")
            state.currentUser = makeUser(id: "uid-1", name: "Me")
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            if video { state.startOutgoingVideoCall(to: peer, cameraEnabled: false) }
            else { state.startOutgoingVoiceCall(to: peer) }
            for _ in 0..<200 where state.activeVoiceCall == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(state.activeVoiceCall?.callID, "policy-call")
            XCTAssertTrue(state.activeVoiceCall?.requiresAcceptedDeviceBeforeJoin == true)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/rooms/policy-room/join"), 0)
            let payload: [String: JSONValue] = ["call": .object([
                "id": .string("policy-call"), "room_id": .string("policy-room"), "status": .string("accepted"),
                "caller_uid": .string("uid-1"), "callee_uid": .string(peer.id), "state_version": .int(2),
                "caller_device": .object(["uid": .string("uid-1"), "device_id": .string("unit-test-device"), "app_id": .string(IMAPIContext.canonicalIOSAppID)]),
                "accepted_device": .object(["uid": .string(peer.id), "device_id": .string("winning-device"), "app_id": .string("callee-app")])
            ])]
            state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(type: "rtc.call.accepted", requestID: nil, payload: payload))
            for _ in 0..<200 where transport.requestCount(path: "/api/rtc/rooms/policy-room/join") == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/rooms/policy-room/join"), 1)
            XCTAssertEqual(state.activeVoiceCall?.callID, "policy-call")
            XCTAssertNotEqual(state.activeVoiceCall?.mediaState, .failed)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/policy-call/cancel"), 0)
            state.activeVoiceCall = nil
        }
    }

    @MainActor
    func testOutgoingVideoDelayedProviderStageCannotPolluteNextLicenseGeneration() async throws {
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 150_000_000,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "video-delayed-provider-peer", name: "Video Peer")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.videoCallPreview = VideoCallPreview(
            id: "video-delayed-provider-old",
            peer: peer,
            channelID: "uid-1:video-delayed-provider-peer",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )

        state.startOutgoingVideoCallFromPreview()
        for _ in 0..<200 where transport.requestCount(path: "/api/tenant/files/config") == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 1)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.videoCallPreview = VideoCallPreview(
            id: "video-delayed-provider-new",
            peer: peer,
            channelID: "uid-1:video-delayed-provider-peer",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(state.videoCallPreview?.id, "video-delayed-provider-new")
        XCTAssertNil(state.videoCallPreview?.startError)
        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
    }

    @MainActor
    func testIncomingVideoAcceptClearsRevokedCallWhenMicrophoneDecisionReturnsDenied() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-permission-denied",
            callID: "incoming-video-permission-denied",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let microphoneDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(microphoneDecisionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        await permissionDecision.resume(returning: false)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-permission-denied/accept"),
            0
        )
    }

    @MainActor
    func testVideoPreviewRevocationClearsPendingPermissionAndCannotRestoreStalePreview() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let videoClient = TestVideoMediaClient()
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            videoPermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "preview-revocation-peer", name: "Preview Peer")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )

        state.presentVideoCallPreview(to: peer)

        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let videoDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(videoDecisionIsWaiting)
        XCTAssertNotNil(state.videoCallPreview)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        XCTAssertNil(state.videoCallPreview)
        XCTAssertFalse(state.isStartingVideoCall)

        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.videoCallPreview)
        XCTAssertEqual(videoClient.prepareCount, 0)
        XCTAssertTrue(videoClient.stopReasons.isEmpty, "Unstarted preview does not own capture to stop")
    }

    func testRTCLicenseSystemAnswerDenialCleansOnceWithoutEndingAnotherOwnedCall() async {
        for unknown in [false, true] {
            for videoAsAudio in [false, true] {
                for preserveConnected in [false, true] {
                    let transport = RTCSystemEndHTTPTransport()
                    let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["denied-system", "other-connected"])
                    let voice = TestVoiceMediaClient()
                    let video = TestVideoMediaClient()
                    var permissions = 0
                    let state = AppState(
                        api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice,
                        videoMediaClient: video, voiceCallSystem: system,
                        microphonePermissionDecisionOverride: { permissions += 1; return true },
                        apiContextOverride: makeAuthenticatedAPIContext()
                    )
                    state.fileUploadConfig = unknown ? .defaultValue : callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
                    if preserveConnected {
                        var active = makeRTCMediaHeartbeatVideoCall(callID: "other-connected")
                        active.mediaState = .connected
                        active.isRecoveringNetwork = unknown
                        active.connectedAt = Date()
                        state.activeVoiceCall = active
                        _ = state.callStore.claimLifecycle(scopeID: "license-system-test", callID: "other-connected", direction: .outgoing, stateVersion: 1)
                        _ = state.callStore.advanceLifecycle(callID: "other-connected", to: .connected, stateVersion: 2)
                        if unknown {
                            _ = state.callStore.advanceLifecycle(callID: "other-connected", to: .reconnecting, stateVersion: 3)
                        }
                    } else {
                        _ = state.callStore.claimLifecycle(scopeID: "license-system-test", callID: "denied-system", direction: .incoming, stateVersion: 1)
                    }
                    state.incomingVoiceCall = IncomingVoiceCall(
                        id: "denied-system", callID: "denied-system", caller: makeUser(id: "peer", name: "Peer"),
                        startedAt: "刚刚", source: "好友通话", requestedMediaMode: videoAsAudio ? "video" : "audio"
                    )
                    for _ in 0..<2 {
                        state.handleVoiceCallSystemEventForTesting(.answer(callID: "denied-system"))
                    }
                    for _ in 0..<100 {
                        if transport.requestCount(path: "/api/rtc/calls/denied-system/reject") > 0 { break }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    XCTAssertNil(state.incomingVoiceCall)
                    XCTAssertFalse(system.hasPresentedCall(callID: "denied-system"))
                    XCTAssertEqual(system.endedCalls.filter { $0.callID == "denied-system" }.count, 1)
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/denied-system/reject"), 1)
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/denied-system/accept"), 0)
                    XCTAssertEqual(permissions, 0)
                    XCTAssertTrue(voice.startedContexts.isEmpty)
                    XCTAssertEqual(video.startCount, 0)
                    XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认语音通话权限，请稍后重试" : "该企业未开通语音通话")
                    if preserveConnected {
                        XCTAssertEqual(state.activeVoiceCall?.callID, "other-connected")
                        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, "other-connected")
                        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, unknown ? .reconnecting : .connected)
                        XCTAssertTrue(system.hasPresentedCall(callID: "other-connected"))
                        XCTAssertTrue(system.endedCalls.allSatisfy { $0.callID != "other-connected" })
                    } else {
                        XCTAssertNil(state.activeVoiceCall)
                        XCTAssertNil(state.callStore.activeLifecycleSnapshot)
                    }
                }
            }
        }
    }

    func testRTCLicenseRepeatedSystemAnswerPreservesSameEstablishedCall() async {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["already-connected"])
        let state = AppState(api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                             apiContextOverride: makeAuthenticatedAPIContext())
        state.fileUploadConfig = .defaultValue
        var active = makeRTCMediaHeartbeatVideoCall(callID: "already-connected")
        active.connectedAt = Date()
        active.mediaState = .connected
        active.isRecoveringNetwork = true
        state.activeVoiceCall = active
        _ = state.callStore.claimLifecycle(scopeID: "same-call", callID: "already-connected", direction: .incoming, stateVersion: 1)
        _ = state.callStore.advanceLifecycle(callID: "already-connected", to: .connected, stateVersion: 2)
        state.incomingVoiceCall = IncomingVoiceCall(id: "already-connected", callID: "already-connected",
            caller: active.peer, startedAt: "刚刚", source: "系统视频来电", requestedMediaMode: "video")
        for _ in 0..<2 { state.handleVoiceCallSystemEventForTesting(.answer(callID: "already-connected")) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.callID, "already-connected")
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, .connected)
        XCTAssertTrue(system.hasPresentedCall(callID: "already-connected"))
        XCTAssertTrue(system.endedCalls.isEmpty)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/already-connected/reject"), 0)
    }

    func testRTCSystemAnswerFreshConfigDenialCleansAfterIncomingUIInvalidation() async {
        let fields = [#""voice_call_enabled":false,"video_call_enabled":false,"#,
                      "", #""voice_call_enabled":null,"video_call_enabled":null,"#]
        for licenseFields in fields {
            for (videoAsAudio, established) in [(false, 0), (true, 0), (false, 1), (true, 2)] {
                let gate = SuspendedBoolDecision()
                let transport = RTCSystemEndHTTPTransport(fileConfigDecision: gate, fileConfigLicenseFields: licenseFields)
                let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["fresh-denial", "other-established"])
                let voice = TestVoiceMediaClient()
                let video = TestVideoMediaClient()
                var permissions = 0
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice,
                    videoMediaClient: video, voiceCallSystem: system,
                    microphonePermissionDecisionOverride: { permissions += 1; return true },
                    apiContextOverride: makeAuthenticatedAPIContext()
                )
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(id: "fresh-denial", callID: "fresh-denial", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友通话", requestedMediaMode: videoAsAudio ? "video" : "audio")
                state.handleVoiceCallSystemEventForTesting(.answer(callID: "fresh-denial"))
                for _ in 0..<200 {
                    if await gate.isWaiting() { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let waiting = await gate.isWaiting()
                XCTAssertTrue(waiting)
                if established > 0 {
                    var active = makeRTCMediaHeartbeatVideoCall(callID: "other-established")
                    active.mediaState = .connected
                    active.connectedAt = Date()
                    active.isRecoveringNetwork = established == 2
                    state.activeVoiceCall = active
                    _ = state.callStore.claimLifecycle(scopeID: "fresh-denial-test", callID: "other-established", direction: .outgoing, stateVersion: 1)
                    _ = state.callStore.advanceLifecycle(callID: "other-established", to: .connected, stateVersion: 2)
                    if established == 2 {
                        _ = state.callStore.advanceLifecycle(callID: "other-established", to: .reconnecting, stateVersion: 3)
                    }
                }
                await gate.resume(returning: true)
                for _ in 0..<200 {
                    if transport.requestCount(path: "/api/rtc/calls/fresh-denial/reject") == 1,
                       state.directCallTrackingCountsForTesting.resourceOwners == 0 { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                state.handleVoiceCallSystemEventForTesting(.answer(callID: "fresh-denial"))
                for _ in 0..<20 { await Task.yield() }
                XCTAssertNil(state.incomingVoiceCall)
                if established > 0 {
                    XCTAssertEqual(state.activeVoiceCall?.callID, "other-established")
                    XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, "other-established")
                    XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, established == 2 ? .reconnecting : .connected)
                    XCTAssertTrue(system.hasPresentedCall(callID: "other-established"))
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/other-established/reject"), 0)
                } else {
                    XCTAssertNil(state.callStore.activeLifecycleSnapshot)
                }
                XCTAssertEqual(system.endedCalls.filter { $0.callID == "fresh-denial" }.count, 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/fresh-denial/reject"), 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/fresh-denial/accept"), 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
                XCTAssertEqual(permissions, 0)
                XCTAssertTrue(voice.startedContexts.isEmpty)
                XCTAssertEqual(video.startCount, 0)
            }
        }
    }

    func testRTCSystemAnswerExplicitEndWhileConfigPendingDoesNotDuplicateCleanup() async {
        for systemEnd in [false, true] {
            let gate = SuspendedBoolDecision()
            let transport = RTCSystemEndHTTPTransport(fileConfigDecision: gate, fileConfigLicenseFields: #""voice_call_enabled":false,"video_call_enabled":false,"#)
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["explicit-end"])
            var permissions = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                microphonePermissionDecisionOverride: { permissions += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: "explicit-end", callID: "explicit-end", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: "explicit-end"))
            for _ in 0..<200 {
                if await gate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await gate.isWaiting()
            XCTAssertTrue(waiting)
            if systemEnd { state.handleVoiceCallSystemEventForTesting(.end(callID: "explicit-end", reason: "callkit_end")) }
            else { state.declineIncomingVoiceCall() }
            await gate.resume(returning: true)
            for _ in 0..<200 {
                if transport.requestCount(path: "/api/rtc/calls/explicit-end/reject") == 1,
                   state.directCallTrackingCountsForTesting.resourceOwners == 0 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/explicit-end/reject"), 1)
            XCTAssertLessThanOrEqual(system.endedCalls.filter { $0.callID == "explicit-end" }.count, 1)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/explicit-end/accept"), 0)
            XCTAssertEqual(permissions, 0)
            XCTAssertNil(state.incomingVoiceCall)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
        }
    }

    func testRTCSystemAnswerStalePermissionCannotEndReplacementOperationOrScope() async {
        for replacement in ["different-call", "same-call", "context-aba"] {
            let oldPermissionGate = SuspendedBoolDecision()
            let newPermissionGate = SuspendedBoolDecision()
            let transport = RTCSystemEndHTTPTransport(fileConfigLicenseFields: #""voice_call_enabled":true,"video_call_enabled":true,"#)
            let newCallID = replacement == "different-call" ? "new-operation" : "old-operation"
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["old-operation", newCallID])
            let original = makeAuthenticatedAPIContext()
            var permissionIndex = 0
            var oldPermissionReturned = false
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                microphonePermissionDecisionOverride: {
                    permissionIndex += 1
                    if permissionIndex == 1 {
                        let decision = await oldPermissionGate.wait()
                        oldPermissionReturned = true
                        return decision
                    }
                    return await newPermissionGate.wait()
                }, apiContextOverride: original
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            let peer = makeUser(id: "peer", name: "Peer")
            state.incomingVoiceCall = IncomingVoiceCall(id: "old-operation", callID: "old-operation", caller: peer, startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: "old-operation"))
            for _ in 0..<200 {
                if await oldPermissionGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let oldWaiting = await oldPermissionGate.isWaiting()
            XCTAssertTrue(oldWaiting)
            if replacement == "context-aba" {
                var other = original
                other.imToken = "replacement-session"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(original)
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            }
            state.incomingVoiceCall = IncomingVoiceCall(id: "replacement", callID: newCallID, caller: peer, startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: newCallID))
            for _ in 0..<200 {
                if await newPermissionGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let replacementWaiting = await newPermissionGate.isWaiting()
            XCTAssertTrue(replacementWaiting)
            let endsBefore = system.endedCalls.filter { $0.callID == newCallID }.count
            let rejectsBefore = transport.requestCount(path: "/api/rtc/calls/\(newCallID)/reject")
            await oldPermissionGate.resume(returning: false)
            for _ in 0..<200 {
                if oldPermissionReturned, state.directCallTrackingCountsForTesting.resourceOwners == 1,
                   replacement != "different-call" || transport.requestCount(path: "/api/rtc/calls/old-operation/reject") == 1 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(oldPermissionReturned)
            for _ in 0..<20 { await Task.yield() }
            if replacement == "different-call" {
                XCTAssertEqual(system.endedCalls.filter { $0.callID == "old-operation" }.count, 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/old-operation/reject"), 1)
            }
            XCTAssertEqual(system.endedCalls.filter { $0.callID == newCallID }.count, endsBefore)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(newCallID)/reject"), rejectsBefore)
            XCTAssertTrue(system.hasPresentedCall(callID: newCallID))
            // Discard the replacement's suspended permission without creating media.
            state.declineIncomingVoiceCall()
            await newPermissionGate.resume(returning: false)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(newCallID)/accept"), 0)
        }
    }

    func testRTCPreviewProviderAuthorityPrecedesCameraAndAllowsVideoOnlyTenant() async {
        for scenario in ["disabled", "missing", "unavailable", "network", "video-only"] {
            let transport = VideoCallStartHTTPTransport(
                fileConfigDelayNanoseconds: 0, providerStatusCode: scenario == "unavailable" ? 503 : 200,
                voiceEnabled: false, providerErrorCode: "rtc_license_capabilities_unavailable",
                providerOmitsLicense: scenario == "missing", providerNetworkFailure: scenario == "network",
                providerVideoEnabled: scenario != "disabled"
            )
            let video = TestVideoMediaClient()
            var permissions = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                videoPermissionDecisionOverride: { permissions += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            let peer = makeUser(id: "preview-provider-peer", name: "Peer")
            state.currentUser = makeUser(id: "uid-1", name: "Me")
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if state.rtcCapabilityAlertMessage != nil || video.prepareCount > 0 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if scenario == "video-only" {
                XCTAssertNil(state.rtcCapabilityAlertMessage)
                XCTAssertEqual(permissions, 1)
                XCTAssertEqual(video.prepareCount, 1)
            } else {
                XCTAssertEqual(state.rtcCapabilityAlertMessage, scenario == "disabled" ? "该企业未开通视频通话" : "暂时无法确认视频通话权限，请稍后重试")
                XCTAssertEqual(permissions, 0, scenario)
                XCTAssertEqual(video.prepareCount, 0, scenario)
            }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            XCTAssertEqual(video.startCount, 0)
            state.dismissVideoCallPreview()
        }
    }

    func testRTCPreviewPermissionCallbackCannotReviveAfterLicenseOrSessionABA() async {
        for sessionABA in [false, true] {
            let permission = SuspendedBoolDecision()
            let video = TestVideoMediaClient()
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let original = makeAuthenticatedAPIContext()
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                videoPermissionDecisionOverride: { await permission.wait() }, apiContextOverride: original
            )
            let peer = makeUser(id: "preview-aba-peer", name: "Peer")
            state.currentUser = makeUser(id: "uid-1", name: "Me")
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if await permission.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await permission.isWaiting()
            XCTAssertTrue(waiting)
            if sessionABA {
                var other = original
                other.imToken = "preview-session-b"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(original)
            } else {
                state.fileUploadConfig = .defaultValue
            }
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            await permission.resume(returning: true)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(video.prepareCount, 0, "A stale granted permission must not activate the camera")
            XCTAssertEqual(video.startCount, 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            state.dismissVideoCallPreview()
        }
    }

    func testRTCPreviewPrepareCompletionCannotReviveAfterLicenseOrSessionABA() async {
        for sessionABA in [false, true] {
            let prepare = SuspendedBoolDecision()
            let video = TestVideoMediaClient()
            video.firstPrepareDecision = prepare
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let context = makeAuthenticatedAPIContext()
            let state = AppState(api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                                 videoPermissionDecisionOverride: { true }, apiContextOverride: context)
            let peer = makeUser(id: "prepare-aba", name: "Peer")
            state.currentUser = makeUser(id: "uid-1", name: "Me")
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if await prepare.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await prepare.isWaiting()
            XCTAssertTrue(waiting)
            if sessionABA {
                var other = context
                other.imToken = "prepare-session-b"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(context)
            } else {
                state.fileUploadConfig = .defaultValue
            }
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            await prepare.resume(returning: true)
            for _ in 0..<200 {
                if state.videoCallPreview == nil, video.previewEvents.last == "stop" { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNil(state.videoCallPreview)
            XCTAssertEqual(video.prepareCount, 1)
            XCTAssertNil(video.preparedGeneration)
            XCTAssertEqual(video.previewEvents.last, "stop")
            XCTAssertEqual(video.stopReasons.count, 1)
            XCTAssertEqual(video.startCount, 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
        }
    }

    func testRTCPreviewReplacementWaitsForOldPrepareCleanupWithoutStoppingNewOwner() async {
        let prepare = SuspendedBoolDecision()
        let video = TestVideoMediaClient()
        video.firstPrepareDecision = prepare
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let state = AppState(
            api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
            videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext()
        )
        let firstPeer = makeUser(id: "preview-first", name: "First")
        let secondPeer = makeUser(id: "preview-second", name: "Second")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [firstPeer, secondPeer]
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.presentVideoCallPreview(to: firstPeer)
        for _ in 0..<200 {
            if await prepare.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await prepare.isWaiting()
        XCTAssertTrue(waiting)
        state.dismissVideoCallPreview()
        state.presentVideoCallPreview(to: secondPeer)
        let replacementID = state.videoCallPreview?.id
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(video.prepareCount, 1, "New prepare must wait until stale SDK work is cleaned up")
        await prepare.resume(returning: true)
        for _ in 0..<200 {
            if video.preparedGeneration == 2, state.videoCallPreview?.isPreparing == false { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.videoCallPreview?.id, replacementID)
        XCTAssertEqual(state.videoCallPreview?.peer.id, secondPeer.id)
        XCTAssertEqual(video.prepareCount, 2)
        XCTAssertEqual(video.preparedGeneration, 2)
        XCTAssertEqual(video.previewEvents.last, "prepared:2", "Old cleanup must not stop the replacement camera")
        XCTAssertTrue(video.previewEvents.contains("stop"))
        state.dismissVideoCallPreview()
    }

    @MainActor
    func testIncomingVideoAcceptAfterServerAcceptCleansOldCallWhenTenantChangesDuringJoin() async throws {
        let joinDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200,
            incomingVideoJoinDecision: joinDecision
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-after-accept",
            callID: "incoming-video-after-accept",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await joinDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let joinIsWaiting = await joinDecision.isWaiting()
        XCTAssertTrue(joinIsWaiting)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/accept"),
            1
        )

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-after-accept"
        switchedContext.imUID = "uid-after-accept"
        switchedContext.imToken = "im-token-after-accept"
        state.overrideAPIContextForTesting(switchedContext)
        await joinDecision.resume(returning: true)
        for _ in 0..<200 where
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/hangup") == 0
                || state.directCallTrackingCountsForTesting.attempts != 0
                || state.directCallTrackingCountsForTesting.resourceOwners != 0
                || state.directCallTrackingCountsForTesting.cleanupObligations != 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/hangup"),
            1
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: reproduce the two review timing windows, not just an earlier refresh.
    func testQueuedTerminalCleanupUsesRetainedCredentialAfterRefreshAndNewLogin() async throws {
        let callID = "queued-cleanup-new-login"
        let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "audio", peerUID: "peer", firstJoinGate: FirstJoinSuspensionGate())
        var context = makeAuthenticatedAPIContext()
        context.tenantAuthSession = IMStoredAuthSession(sessionID: "queued-session", refreshToken: "test-refresh", tokenType: "tenant")
        let state = AppState(api: makeCallEndingAPI(transport: transport), apiContextOverride: context)
        state.pendingRTCTerminalCompensations[callID] = PendingRTCTerminalCompensation(
            callID: callID, action: .hangup, reason: "setup_failed", context: context,
            scope: state.remoteDataScopeKey(for: context), idempotencyKey: "queued-stable-key",
            attemptCount: 0, nextAttemptAtNanoseconds: 0, lastErrorCode: nil)
        state.retryPendingRTCTerminalCompensationsForTesting()
        // No await: the retry Task is enqueued but cannot run on MainActor before these two changes.
        context.imToken = "last-owned-token"
        context.credentialRevision += 1
        state.overrideAPIContextForTesting(context)
        context.sessionEpoch = "new-login"
        context.imToken = "new-login-must-not-be-used"
        state.overrideAPIContextForTesting(context)
        for _ in 0..<200 where state.pendingRTCTerminalCompensationCountForTesting != 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        let path = "/api/rtc/calls/\(callID)/hangup"
        XCTAssertEqual(transport.requestCount(path: path), 1)
        XCTAssertEqual(transport.authorizationHeader(path: path), "Bearer last-owned-token")
        XCTAssertEqual(transport.idempotencyKeys(path: path), ["queued-stable-key"])
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
    }

    func testAcceptResponseAfterRefreshThenJoinAfterNewLoginKeepsOwnedCredential() async throws {
        for (callType, mode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            let acceptGate = FirstJoinSuspensionGate(), joinGate = FirstJoinSuspensionGate()
            let callID = "accept-refresh-\(callType)-\(mode)"
            let peer = makeUser(id: "accept-peer", name: "Peer")
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: joinGate, acceptGate: acceptGate, acceptedMediaMode: mode)
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(sessionID: "accept-session", refreshToken: "test-refresh", tokenType: "tenant")
            let voice = TestVoiceMediaClient(), video = TestVideoMediaClient()
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, videoMediaClient: video,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: context)
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: callType)
            if callType == "audio" { state.acceptIncomingVoiceCall() } else { state.acceptIncomingVideoCall(as: mode) }
            for _ in 0..<200 { if await acceptGate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let acceptWaiting = await acceptGate.isWaiting(); XCTAssertTrue(acceptWaiting, callID)
            context.imToken = "accept-refreshed-token"; context.credentialRevision += 1
            state.overrideAPIContextForTesting(context)
            await acceptGate.resumeFirst()
            for _ in 0..<200 { if await joinGate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let joinWaiting = await joinGate.isWaiting(); XCTAssertTrue(joinWaiting, callID)
            context.sessionEpoch = "replacement-login"; context.imToken = "replacement-must-not-be-used"
            state.overrideAPIContextForTesting(context)
            await joinGate.resumeFirst()
            let path = "/api/rtc/calls/\(callID)/hangup"
            for _ in 0..<200 where transport.requestCount(path: path) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(transport.authorizationHeader(path: path), "Bearer accept-refreshed-token", callID)
            XCTAssertEqual(transport.requestCount(path: path), 1, callID)
            XCTAssertTrue(voice.startedContexts.isEmpty); XCTAssertEqual(video.startCount, 0)
        }
    }
    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END

    @MainActor
    func testIncomingVoiceStaleJoinCannotClearOrHangupSameCallOwnedByReplacementSession() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-voice-same-call-owner"
        let peer = makeUser(id: "incoming-voice-owner-peer", name: "Voice Peer")
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "audio",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-same-call",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let firstVoiceJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(firstVoiceJoinIsWaiting)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-voice-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVoiceCall()

        for _ in 0..<200 where state.activeVoiceCall == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let replacementActiveID = try XCTUnwrap(state.activeVoiceCall?.id)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 2)

        await joinGate.resumeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.activeVoiceCall?.id, replacementActiveID)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/hangup"), 0)
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: replay notification feedback and delayed work after hangup.
    func testAudioRouteFeedbackDoesNotReconfigureAndOldTaskCannotReviveEndedCall() async throws {
        let voice = TestVoiceMediaClient()
        let state = AppState(voiceMediaClient: voice, apiContextOverride: makeAuthenticatedAPIContext())
        state.activeVoiceCall = VoiceCallSession(
            id: "route-owner",
            callID: "route-call",
            peer: makeUser(id: "peer", name: "Peer"),
            direction: "来电",
            startedAt: "now",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: false
        )
        for _ in 0..<346 {
            state.handleCallAudioRouteChange(.categoryChange)
            state.handleCallAudioRouteChange(.override)
            state.handleCallAudioRouteChange(.routeConfigurationChange)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(voice.audioReconcileSpeakerValues.isEmpty)
        state.handleCallAudioRouteChange(.newDeviceAvailable)
        for _ in 0..<20 where voice.audioReconcileSpeakerValues.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(voice.audioReconcileSpeakerValues, [false])
        state.handleCallAudioRouteChange(.oldDeviceUnavailable)
        state.activeVoiceCall = nil
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(
            voice.audioReconcileSpeakerValues,
            [false],
            "queued work after hangup must not reconfigure shared audio"
        )
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: app UI must request the existing CallKit answer then wait for activation.
    // Independent review regression: echo of in-app CXAnswerCallAction must not reject valid video-only call.
    @MainActor
    func testInAppVideoAnswerCallKitEchoPreservesVideoOnlyLicense() async throws {
        for voiceEnabled in [true, false] {
            let callID = "review-echo-video-\(voiceEnabled)", gate = FirstJoinSuspensionGate()
            let peer = makeUser(id: "review-peer", name: "Peer")
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let video = TestVideoMediaClient()
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "video", peerUID: peer.id, firstJoinGate: gate, acceptedMediaMode: "video", voiceEnabled: voiceEnabled)
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: TestVoiceMediaClient(), videoMediaClient: video, voiceCallSystem: system,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
            system.onAnswerRequest = { [weak state] callID in
                state?.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            }
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: voiceEnabled, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: "video")
            state.acceptIncomingVideoCall(as: "video")
            for _ in 0..<200 { if await gate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let waiting = await gate.isWaiting(); XCTAssertTrue(waiting, callID)
            XCTAssertEqual(system.requestedAnswers, [callID])
            XCTAssertEqual(state.incomingCallAnswerMode, "video", callID)
            XCTAssertEqual(state.fileUploadConfig.voiceCallEnabled, voiceEnabled)
            // Real CXProviderDelegate emits this for the action requested above.
            state.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            XCTAssertTrue(system.endedCalls.isEmpty, "Self-generated answer must not end \(callID)")
            XCTAssertEqual(state.incomingVoiceCall?.callID, callID, "Self-generated answer must preserve incoming owner")
            XCTAssertEqual(state.incomingCallAnswerMode, "video")
            await gate.resumeFirst()
            state.handleVoiceCallSystemEventForTesting(.audioSessionActivated)
            for _ in 0..<200 where video.startCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(video.startCount, 1, callID)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/reject"), 0, callID)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    func testInAppCallKitAnswerWaitsForAudioActivationForAllIncomingModes() async throws {
        for (callType, mode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            let callID = "system-answer-\(callType)-\(mode)", gate = FirstJoinSuspensionGate()
            let peer = makeUser(id: "system-peer", name: "Peer")
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let voice = TestVoiceMediaClient(), video = TestVideoMediaClient()
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: gate, acceptedMediaMode: mode)
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, videoMediaClient: video, voiceCallSystem: system,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
            system.onAnswerRequest = { [weak state] callID in
                state?.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            }
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: callType)
            if callType == "audio" { state.acceptIncomingVoiceCall() } else { state.acceptIncomingVideoCall(as: mode) }
            for _ in 0..<200 { if await gate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let waiting = await gate.isWaiting(); XCTAssertTrue(waiting, callID)
            XCTAssertEqual(system.requestedAnswers, [callID])
            await gate.resumeFirst()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(voice.startedContexts.isEmpty, callID); XCTAssertEqual(video.startCount, 0, callID)
            state.handleVoiceCallSystemEventForTesting(.audioSessionActivated)
            for _ in 0..<200 where voice.startedContexts.isEmpty && video.startCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(voice.startedContexts.count, mode == "audio" ? 1 : 0, callID)
            XCTAssertEqual(video.startCount, mode == "video" ? 1 : 0, callID)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
        }
    }
    func testSystemAnswerDoesNotDeduplicateUnrelatedOrInvalidatedOperation() async throws {
        for mismatch in ["call", "operation", "generation", "license"] {
            let callID = "system-answer-ownership-\(mismatch)"
            let context = makeAuthenticatedAPIContext()
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let transport = RTCSystemEndHTTPTransport()
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                                 apiContextOverride: context)
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: mismatch != "license")
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID,
                caller: makeUser(id: "peer", name: "Peer"), startedAt: "now", source: "test", requestedMediaMode: "video")
            let operationID = UUID()
            state.callStore.incomingCallAnswerOperationID = operationID
            state.incomingCallAnswerMode = "video"
            state.directCallAttempts[.video] = DirectCallAttempt(kind: .video,
                context: DirectCallContextBinding(context: context),
                capabilityGeneration: state.directCallCapabilityGeneration(for: .video) + (mismatch == "generation" ? 1 : 0),
                callID: mismatch == "call" ? "other-call" : callID, peerID: "peer", mediaMode: "video",
                operationID: mismatch == "operation" ? UUID() : operationID)
            state.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/\(callID)/reject") == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(system.endedCalls.map(\.callID), [callID], mismatch)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/reject"), 1, mismatch)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 0, mismatch)
            XCTAssertTrue(system.requestedAnswers.isEmpty, mismatch)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    func testInAppCallKitAnswerTransactionFailureNeverAcceptsOrStartsMedia() async throws {
        let callID = "system-answer-denied"
        let peer = makeUser(id: "system-peer", name: "Peer")
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
        system.answerRequestError = NSError(domain: "com.apple.CallKit.error.requesttransaction", code: 4)
        let voice = TestVoiceMediaClient()
        let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "audio", peerUID: peer.id, firstJoinGate: FirstJoinSuspensionGate())
        let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 where system.endedCalls.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(system.requestedAnswers, [callID])
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 0)
        XCTAssertTrue(voice.startedContexts.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: callID))
        XCTAssertEqual(system.endedCalls.count, 1)
        state.clearRTCTerminalCompensationsForTesting()
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END

    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: restore focused refresh/owner regression coverage on the new baseline.
    @MainActor
    func testRefreshedAcceptedCallFailureCleansWithOwnedLatestCredential() async throws {
        for (callType, answerMode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            for switchSession in [false, true] {
                let gate = FirstJoinSuspensionGate()
                let callID = "refresh-cleanup-\(callType)-\(answerMode)-\(switchSession)"
                let peer = makeUser(id: "refresh-cleanup-peer", name: "Peer")
                let transport = IncomingSameCallOwnershipHTTPTransport(
                    callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: gate,
                    gateStage: switchSession ? "join" : "provider", acceptedMediaMode: answerMode,
                    failJoin: true
                )
                var context = makeAuthenticatedAPIContext()
                context.tenantAuthSession = IMStoredAuthSession(
                    sessionID: "stable-cleanup-session", refreshToken: "test-refresh", tokenType: "tenant"
                )
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport), voiceMediaClient: TestVoiceMediaClient(),
                    videoMediaClient: TestVideoMediaClient(), microphonePermissionDecisionOverride: { true },
                    videoPermissionDecisionOverride: { true }, apiContextOverride: context
                )
                state.voiceMediaClientAvailableOverride = true
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(
                    id: callID, callID: callID, caller: peer, startedAt: "now", source: "test",
                    requestedMediaMode: callType
                )
                if callType == "audio" { state.acceptIncomingVoiceCall() }
                else { state.acceptIncomingVideoCall(as: answerMode) }
                for _ in 0..<200 {
                    if await gate.isWaiting() { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let waiting = await gate.isWaiting()
                XCTAssertTrue(waiting, callID)
                context.imToken = "rotated-cleanup-token"
                context.credentialRevision += 1
                state.overrideAPIContextForTesting(context)
                if switchSession {
                    // A -> refresh -> B: old cleanup must keep A's last token, never B's.
                    context.sessionEpoch = "replacement-login"
                    context.imToken = "different-login-token"
                    state.overrideAPIContextForTesting(context)
                }
                await gate.resumeFirst()
                let hangup = "/api/rtc/calls/\(callID)/hangup"
                for _ in 0..<200 where transport.requestCount(path: hangup) == 0 {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertEqual(transport.requestCount(path: hangup), 1, callID)
                XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer rotated-cleanup-token", callID)
                XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/accept"),
                               switchSession ? "Bearer im-token" : "Bearer rotated-cleanup-token", callID)
                XCTAssertNil(state.activeVoiceCall)
            }
        }
    }

    @MainActor
    func testTerminalCleanupRetryRefreshesOwnedCredentialsAndKeepsIdempotency() async throws {
        for switchSession in [false, true] {
            let callID = "cleanup-retry-\(switchSession)"
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID, callType: "audio", peerUID: "peer", firstJoinGate: FirstJoinSuspensionGate(),
                hangupFailures: 1
            )
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "retry-session", refreshToken: "test-refresh", tokenType: "tenant"
            )
            var now: UInt64 = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), rtcRequestNowNanoseconds: { now },
                rtcTerminalCompensationFailureDelayNanoseconds: [60_000_000_000], apiContextOverride: context
            )
            // An already queued cleanup uses the same production retry path as setup failure.
            state.pendingRTCTerminalCompensations[callID] = PendingRTCTerminalCompensation(
                callID: callID, action: .hangup, reason: "setup_failed", context: context,
                scope: state.remoteDataScopeKey(for: context), idempotencyKey: "stable-test-cleanup-key",
                attemptCount: 0, nextAttemptAtNanoseconds: 0, lastErrorCode: nil
            )
            state.retryPendingRTCTerminalCompensationsForTesting()
            for _ in 0..<200 where state.pendingRTCTerminalCompensations[callID]?.lastErrorCode == nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let hangup = "/api/rtc/calls/\(callID)/hangup"
            XCTAssertEqual(transport.requestCount(path: hangup), 1)
            XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer im-token")
            context.imToken = "retry-refreshed-token"
            context.credentialRevision += 1
            state.overrideAPIContextForTesting(context)
            if switchSession {
                context.sessionEpoch = "different-retry-login"
                context.imToken = "must-not-use-new-login-token"
                state.overrideAPIContextForTesting(context)
            }
            now = 120_000_000_000
            state.retryPendingRTCTerminalCompensationsForTesting()
            for _ in 0..<200 where state.pendingRTCTerminalCompensationCountForTesting != 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(transport.requestCount(path: hangup), 2)
            XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer retry-refreshed-token")
            XCTAssertEqual(transport.idempotencyKeys(path: hangup), ["stable-test-cleanup-key", "stable-test-cleanup-key"])
            XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    @MainActor
    func testVideoPreviewAndDowngradeRefreshUseLatestCredentialsWithoutRevivingStaleWork() async throws {
        for action in ["preview", "downgrade"] {
            for stage in ["files", "provider"] {
                for change in ["refresh", "session", "license"] {
                    let gate = FirstJoinSuspensionGate()
                    let callID = "video-\(action)-\(stage)-\(change)"
                    let peer = makeUser(id: "refresh-video-peer", name: "Peer")
                    let transport = IncomingSameCallOwnershipHTTPTransport(
                        callID: callID, callType: "video", peerUID: peer.id, firstJoinGate: gate,
                        gateStage: stage
                    )
                    var context = makeAuthenticatedAPIContext()
                    context.tenantAuthSession = IMStoredAuthSession(
                        sessionID: "stable-video-session", refreshToken: "test-refresh", tokenType: "tenant"
                    )
                    let video = TestVideoMediaClient()
                    let state = AppState(
                        api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                        videoPermissionDecisionOverride: { true }, apiContextOverride: context
                    )
                    state.currentUser = makeUser(id: "uid-1", name: "Me")
                    state.contacts = [peer]
                    state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                    if action == "preview" {
                        state.presentVideoCallPreview(to: peer)
                    } else {
                        state.activeVoiceCall = VoiceCallSession(
                            id: callID, callID: callID, peer: peer, direction: "呼出", startedAt: "now",
                            statusText: "连接中", mediaState: .connecting, isMuted: false, speakerOn: true,
                            requestedMediaMode: "video", mediaMode: "video", localCameraEnabled: true
                        )
                        state.downgradeActiveVideoCallToAudio()
                    }
                    for _ in 0..<200 {
                        if await gate.isWaiting() { break }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    let waiting = await gate.isWaiting()
                    XCTAssertTrue(waiting, callID)
                    context.imToken = "rotated-video-token"
                    context.credentialRevision += 1
                    if change == "session" { context.sessionEpoch = "replacement-video-login" }
                    state.overrideAPIContextForTesting(context)
                    if change == "license" {
                        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
                    }
                    await gate.resumeFirst()
                    if change == "refresh" {
                        for _ in 0..<200 where video.prepareCount + video.downgradeToAudioCount == 0 {
                            try await Task.sleep(nanoseconds: 5_000_000)
                        }
                        XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/provider"),
                                       stage == "files" ? "Bearer rotated-video-token" : "Bearer im-token", callID)
                        if action == "preview" {
                            XCTAssertEqual(video.prepareCount, 1, callID)
                            XCTAssertNotNil(state.videoCallPreview, callID)
                        } else {
                            XCTAssertEqual(video.downgradeToAudioCount, 1, callID)
                            XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/downgrade"),
                                           "Bearer rotated-video-token", callID)
                            XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio", callID)
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        XCTAssertEqual(video.prepareCount, 0, callID)
                        XCTAssertEqual(video.downgradeToAudioCount, 0, callID)
                        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/downgrade"), 0, callID)
                    }
                    if action == "preview" { state.dismissVideoCallPreview() }
                }
            }
        }
    }

    @MainActor
    func testDirectCallBindingPreservesRealSessionAndAuthorityBoundaries() {
        func session(id: String = "stable-session", refresh: String = "test-refresh-token",
                     authVersion: Int64 = 2, generation: Int64 = 3) -> IMStoredAuthSession {
            IMStoredAuthSession(sessionID: id, refreshToken: refresh, tokenType: "tenant",
                                authVersion: authVersion, sessionGeneration: generation)
        }
        var context = makeAuthenticatedAPIContext()
        context.tenantAuthSession = session()
        let original = DirectCallContextBinding(context: context)
        var refreshed = context
        refreshed.imToken = "rotated-test-token"
        refreshed.credentialRevision += 1
        refreshed.tenantAuthSession = session(refresh: "rotated-test-refresh-token", generation: 4)
        XCTAssertEqual(original, DirectCallContextBinding(context: refreshed))

        let identityChanges: [(String, (inout IMAPIContext) -> Void)] = [
            ("account", { $0.accountID = "another-account" }),
            ("tenant", { $0.tenantID = "another-tenant" }),
            ("uid", { $0.imUID = "another-uid" }),
            ("app", { $0.appID = "another-app" }),
            ("device", { $0.deviceID = "another-device" }),
            ("epoch", { $0.sessionEpoch = "another-epoch" }),
            ("session", { $0.tenantAuthSession = session(id: "another-session") }),
            ("authVersion", { $0.tenantAuthSession = session(authVersion: 3) }),
            ("logout", { $0.imToken = nil }),
            ("sessionRemoved", { $0.tenantAuthSession = nil })
        ]
        for (name, change) in identityChanges {
            var changed = context
            change(&changed)
            XCTAssertNotEqual(original, DirectCallContextBinding(context: changed), name)
        }
        var legacy = makeAuthenticatedAPIContext()
        let originalLegacy = DirectCallContextBinding(context: legacy)
        legacy.imToken = "different-legacy-token"
        XCTAssertNotEqual(originalLegacy, DirectCallContextBinding(context: legacy))
    }

    @MainActor
    func testIncomingCallSurvivesSameSessionCredentialRotationDuringJoin() async throws {
        let scenarios = [("audio", "audio"), ("video", "audio"), ("video", "video")].flatMap { callType, answerMode in
            ["provider", "join", "participants"].map { (callType, answerMode, $0) }
        }
        for (callType, answerMode, gateStage) in scenarios {
            let joinGate = FirstJoinSuspensionGate()
            let callID = "incoming-\(callType)-\(answerMode)-\(gateStage)-rotation"
            let peer = makeUser(id: "refresh-peer", name: "Refresh Peer")
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID,
                callType: callType,
                peerUID: peer.id,
                firstJoinGate: joinGate,
                gateStage: gateStage,
                acceptedMediaMode: answerMode
            )
            let media = TestVoiceMediaClient()
            let videoMedia = TestVideoMediaClient()
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "stable-tenant-session",
                refreshToken: "test-refresh-token",
                tokenType: "tenant"
            )
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: media,
                videoMediaClient: videoMedia,
                microphonePermissionDecisionOverride: { true },
                videoPermissionDecisionOverride: { true },
                apiContextOverride: context
            )
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(
                id: callID,
                callID: callID,
                caller: peer,
                startedAt: "刚刚",
                source: "好友通话",
                requestedMediaMode: callType
            )
            if callType == "audio" {
                state.acceptIncomingVoiceCall()
            } else {
                state.acceptIncomingVideoCall(as: answerMode)
            }
            for _ in 0..<200 {
                if await joinGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let joinIsWaiting = await joinGate.isWaiting()
            XCTAssertTrue(joinIsWaiting, callType)

            // Foreground refresh advances credentials without replacing the login session.
            context.imToken = "rotated-test-im-token"
            context.credentialRevision += 1
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "stable-tenant-session", refreshToken: "rotated-test-refresh-token",
                tokenType: "tenant", sessionGeneration: 1
            )
            state.overrideAPIContextForTesting(context)
            await joinGate.resumeFirst()
            let hangupPath = "/api/rtc/calls/\(callID)/hangup"
            for _ in 0..<200 where media.startedContexts.isEmpty && videoMedia.startCount == 0 && transport.requestCount(path: hangupPath) == 0 {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(
                transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/accept"),
                gateStage == "provider" ? "Bearer rotated-test-im-token" : "Bearer im-token",
                "\(callType)/\(gateStage)"
            )
            XCTAssertEqual(media.startedContexts.count, answerMode == "audio" ? 1 : 0, "\(callType)/\(gateStage)")
            XCTAssertEqual(videoMedia.startCount, answerMode == "video" ? 1 : 0, "\(callType)/\(gateStage)")
            XCTAssertEqual(state.activeVoiceCall?.callID, callID, callType)
            XCTAssertEqual(transport.requestCount(path: hangupPath), 0, callType)
        }
    }
    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END

    @MainActor
    func testIncomingVideoStaleJoinCannotClearOrHangupSameCallOwnedByReplacementSession() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-video-same-call-owner"
        let peer = makeUser(id: "incoming-video-owner-peer", name: "Video Peer")
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "video",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-video-same-call",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let firstVideoJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(firstVideoJoinIsWaiting)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-video-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVideoCall(as: "audio")

        for _ in 0..<200 where state.activeVoiceCall == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let replacementActiveID = try XCTUnwrap(state.activeVoiceCall?.id)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 2)

        await joinGate.resumeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.activeVoiceCall?.id, replacementActiveID)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/hangup"), 0)
    }

    @MainActor
    func testIncomingVoiceReplacementProviderDenialCleansTransferredOldCallExactlyOnce() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-voice-provider-denied-owner"
        let peer = makeUser(id: "incoming-voice-provider-peer", name: "Voice Peer")
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "audio",
            peerUID: peer.id,
            firstJoinGate: joinGate,
            providerSuccessLimit: 1
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-provider-denied",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVoiceCall()

        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let oldVoiceJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(oldVoiceJoinIsWaiting)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-provider-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVoiceCall()

        let hangupPath = "/api/rtc/calls/\(callID)/hangup"
        for _ in 0..<200 where transport.requestCount(path: hangupPath) == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 2)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
        XCTAssertEqual(transport.requestCount(path: hangupPath), 1)
        XCTAssertEqual(transport.authorizationHeader(path: hangupPath), "Bearer im-token")
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)

        await joinGate.resumeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: hangupPath), 1)
    }

    @MainActor
    func testIncomingVideoReplacementPermissionDenialCleansTransferredOldCallExactlyOnce() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let permissionDecisions = SequencedBoolDecision([true, false])
        let callID = "incoming-video-permission-denied-owner"
        let peer = makeUser(id: "incoming-video-permission-peer", name: "Video Peer")
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "video",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: {
                await permissionDecisions.next()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-video-permission-denied-owner",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVideoCall(as: "audio")

        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let oldVideoJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(oldVideoJoinIsWaiting)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-permission-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVideoCall(as: "audio")

        let hangupPath = "/api/rtc/calls/\(callID)/hangup"
        for _ in 0..<200 where transport.requestCount(path: hangupPath) == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
        XCTAssertEqual(transport.requestCount(path: hangupPath), 1)
        XCTAssertEqual(transport.authorizationHeader(path: hangupPath), "Bearer im-token")
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)

        await joinGate.resumeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: hangupPath), 1)
    }

    @MainActor
    func testIncomingVoiceRemoteTerminalReleasesAttemptOwnerAndCleanupContext() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-voice-terminal-release"
        let peer = makeUser(id: "incoming-voice-terminal-peer", name: "Voice Peer")
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "audio",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-voice-terminal-release",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.acceptIncomingVoiceCall()

        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let terminalVoiceJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(terminalVoiceJoinIsWaiting)
        await joinGate.resumeFirst()
        for _ in 0..<200
        where state.activeVoiceCall == nil
            || state.directCallTrackingCountsForTesting.cleanupObligations != 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 1)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 1)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)

        state.handleVoiceMediaEvent(.closed, callID: callID)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    @MainActor
    func testAppStateVoiceCallWaitsForFriendRelationsWhenEmptySyncIsRunning() throws {
        let state = AppState()
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let currentUser = makeUser(id: "me", name: "Me")
        let peer = makeUser(id: "peer-1", name: "Peer")

        state.currentUser = currentUser
        XCTAssertTrue(state.contactStore.beginContactsSync())

        XCTAssertFalse(state.canStartVoiceCall(with: peer))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: peer), "好友关系同步中，请稍后再试")

        state.startOutgoingVoiceCall(to: peer)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "好友关系同步中，请稍后再试")
        state.contactStore.finishContactsSync()
    }

    func testDirectPeerContactLookupPreservesAmbiguitySelfExclusionAndFreshSnapshots() {
        let peer = makeUser(id: "peer", name: "Fresh")
        let selfContact = makeUser(id: "self", name: "Self")
        let other = makeUser(id: "other", name: "Other")
        var conversation = makeConversation(id: "self:peer", kind: .direct,
                                            unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        let fixtures = [[peer], [selfContact, peer, other], [peer, peer], [], [other]]
        for contacts in fixtures {
            let lookup = DirectConversationCallPeerResolver.ContactLookup(contacts: contacts)
            for participants in [[], [peer], [selfContact, peer], [peer, other], [selfContact]] {
                conversation.participants = participants
                XCTAssertEqual(
                    DirectConversationCallPeerResolver.resolve(conversation: conversation,
                        currentIdentityIDs: [" self "], contacts: contacts, contactLookup: lookup),
                    DirectConversationCallPeerResolver.resolve(conversation: conversation,
                        currentIdentityIDs: [" self "], contacts: contacts)
                )
                XCTAssertEqual(
                    DirectConversationProfilePeerResolver.resolve(conversation: conversation,
                        currentIdentityIDs: ["self"], contacts: contacts, fallbackEnterprise: "Tenant", contactLookup: lookup),
                    DirectConversationProfilePeerResolver.resolve(conversation: conversation,
                        currentIdentityIDs: ["self"], contacts: contacts, fallbackEnterprise: "Tenant")
                )
            }
        }
        conversation.participants = []
        let fresh = makeUser(id: "peer", name: "New scope")
        let freshLookup = DirectConversationCallPeerResolver.ContactLookup(contacts: [fresh])
        XCTAssertEqual(DirectConversationCallPeerResolver.resolve(conversation: conversation,
            currentIdentityIDs: ["self"], contacts: [fresh], contactLookup: freshLookup)?.name, "New scope")
    }

    @MainActor
    func testDirectConversationCallPeerUsesAuthoritativeParticipantInsteadOfStaleContactOrder() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        let staleWebContact = makeUser(id: "web-user", name: "Old Web Contact")
        let androidPeer = makeUser(id: "android-user", name: "Android Peer")
        var conversation = makeConversation(
            id: "ios-user:web-user",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        conversation.participants = [currentUser, androidPeer]

        state.currentUser = currentUser
        state.contacts = [staleWebContact, androidPeer]

        XCTAssertEqual(state.directConversationCallPeer(for: conversation)?.id, androidPeer.id)
    }

    @MainActor
    func testListProjectionReusesResolvedPeerWithoutChangingCertificationFallbacks() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let current = makeUser(id: "ios-user", name: "Current")
        let peer = makeUser(id: "peer", name: "Peer")
        state.currentUser = current
        state.contacts = [peer]
        var direct = makeConversation(id: "ios-user:peer", kind: .direct, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        direct.participants = [current, peer]
        let resolved = state.directConversationCallPeer(for: direct)
        XCTAssertEqual(state.directConversationCertificationUID(for: direct, resolvedPeer: resolved),
                       state.directConversationCertificationUID(for: direct))

        // Nil means already resolved without a contact; retain the exact old
        // participant/channel fallback, not a different identity authority.
        state.contacts = []
        direct = makeConversation(id: "ios-user:unknown-peer", kind: .direct, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        direct.participants = []
        XCTAssertEqual(state.directConversationCertificationUID(for: direct, resolvedPeer: nil),
                       state.directConversationCertificationUID(for: direct))
        XCTAssertEqual(state.directConversationCertificationUID(for: direct, resolvedPeer: nil), "unknown-peer")
        let group = makeConversation(id: "group", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        XCTAssertNil(state.directConversationCertificationUID(for: group, resolvedPeer: peer))
    }

    @MainActor
    func testDirectConversationCallPeerUsesFreshContactPresenceForKnownParticipant() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        let offlineParticipant = IMUser(
            id: "android-user",
            userID: "WXTNS000032",
            name: "Android Peer",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "离线",
            enterprise: "",
            avatarSeed: 0,
            badges: []
        )
        let onlineContact = IMUser(
            id: "android-user",
            userID: "WXTNS000032",
            name: "Android Peer",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "",
            avatarSeed: 0,
            badges: []
        )
        var conversation = makeConversation(
            id: "ios-user:android-user",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        conversation.participants = [currentUser, offlineParticipant]

        state.currentUser = currentUser
        state.contacts = [onlineContact]

        XCTAssertEqual(state.directConversationCallPeer(for: conversation)?.status, "在线")
    }

    @MainActor
    func testDirectConversationCallPeerResolvesEmptyParticipantsAcrossMultipleContacts() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        let staleWebContact = makeUser(id: "web-user", name: "Old Web Contact")
        let androidPeer = IMUser(
            id: "android-profile-id",
            userID: "android-user",
            name: "Android Peer",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "",
            avatarSeed: 0,
            badges: []
        )
        let conversation = makeConversation(
            id: "android-user:ios-user",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )

        state.currentUser = currentUser
        state.contacts = [staleWebContact, androidPeer]

        XCTAssertEqual(state.directConversationCallPeer(for: conversation)?.id, androidPeer.id)
    }

    @MainActor
    func testDirectConversationCallPeerFailsClosedForUnknownOrAmbiguousTarget() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        let staleWebContact = makeUser(id: "web-user", name: "Old Web Contact")
        let unknownConversation = makeConversation(
            id: "ios-user:unknown-user",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )
        var ambiguousConversation = unknownConversation
        ambiguousConversation.participants = [
            makeUser(id: "peer-a"),
            makeUser(id: "peer-b")
        ]

        state.currentUser = currentUser
        state.contacts = [staleWebContact]

        XCTAssertNil(state.directConversationCallPeer(for: unknownConversation))
        XCTAssertNil(state.directConversationCallPeer(for: ambiguousConversation))
        XCTAssertEqual(DirectConversationCallPeerResolver.unavailableMessage, "目标信息同步中，请稍后再试")
    }

    @MainActor
    func testDirectConversationProfilePeerFallsBackToIncomingMessageSnapshot() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        var conversation = makeConversation(
            id: "opaque-direct-channel",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        var message = makeMessage(id: "m1", senderId: "android-user", seq: 1)
        message = ChatMessage(
            id: message.id,
            senderId: message.senderId,
            senderName: "Android Peer",
            senderAvatarURL: "https://example.invalid/avatar.png",
            senderAvatarVersion: "v1",
            senderAvatarUpdatedAt: "2026-08-19T00:00:00Z",
            senderAvatarSeed: 42,
            text: message.text,
            time: message.time,
            channelSeq: message.channelSeq,
            isOutgoing: false,
            status: .sent,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        conversation.messages = [message]
        state.currentUser = currentUser
        state.contacts = []

        XCTAssertNil(state.directConversationCallPeer(for: conversation))
        let profilePeer = try XCTUnwrap(state.directConversationProfilePeer(for: conversation))
        XCTAssertEqual(profilePeer.id, "android-user")
        XCTAssertEqual(profilePeer.displayName, "Android Peer")
        XCTAssertEqual(profilePeer.avatarVersion, "v1")
    }

    @MainActor
    func testDirectConversationProfilePeerReturnsNilInsteadOfBlankSheetWithoutIdentityEvidence() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        state.currentUser = makeUser(id: "ios-user", name: "iOS User")
        let conversation = makeConversation(
            id: "opaque-direct-channel",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )

        XCTAssertNil(state.directConversationProfilePeer(for: conversation))
        XCTAssertEqual(DirectConversationProfilePeerResolver.unavailableMessage, "联系人资料同步中，请稍后再试")
    }

    @MainActor
    func testVideoPreviewAndVoiceLaunchShareSafeDirectConversationPeer() throws {
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeIsolatedAPIContext()
        )
        let currentUser = makeUser(id: "ios-user", name: "iOS User")
        let staleWebContact = makeUser(id: "web-user", name: "Old Web Contact")
        let androidPeer = makeUser(id: "android-user", name: "Android Peer")
        let conversation = makeConversation(
            id: "android-user:ios-user",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 0,
            lastReadSeq: 0
        )

        state.currentUser = currentUser
        state.contacts = [staleWebContact, androidPeer]
        state.fileUploadConfig = videoCallEnabledFileConfig()

        let voiceTarget = state.directConversationCallPeer(for: conversation)
        let previewTarget = state.directConversationCallPeer(for: conversation)

        XCTAssertEqual(voiceTarget?.id, androidPeer.id)
        XCTAssertEqual(previewTarget?.id, androidPeer.id)
        XCTAssertNotEqual(voiceTarget?.id, staleWebContact.id)

        if let previewTarget {
            state.presentVideoCallPreview(to: previewTarget, channelID: conversation.id)
        }
        XCTAssertEqual(state.videoCallPreview?.peer.id, androidPeer.id)
        XCTAssertEqual(state.videoCallPreview?.channelID, conversation.id)
        state.dismissVideoCallPreview()
    }

    @MainActor
    func testAppStateIncomingVoiceCallFromLocallyUnknownPeerUsesServerSignal() throws {
        let state = AppState()
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")
        let unknownServerPeer = makeUser(id: "stranger-1", name: "Stranger")

        state.currentUser = currentUser
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: unknownServerPeer, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.id, "stranger-1")
    }

    func testRemoteRTCCallEventMergesTopLevelFieldsIntoPayload() throws {
        let data = """
        {
          "id": "evt-1",
          "call_id": "call-1",
          "status": "ringing",
          "caller_uid": "friend-1",
          "target_uid": "me",
          "room_id": "room-1",
          "channel_id": "friend-1:me"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RemoteRTCCallEvent.self, from: data)

        XCTAssertEqual(event.id, "evt-1")
        XCTAssertEqual(event.type, "rtc.call.ringing")
        XCTAssertEqual(event.payload["event"]?.stringValue, "rtc.call.ringing")
        XCTAssertEqual(event.payload["call_id"]?.stringValue, "call-1")
        XCTAssertEqual(event.payload["status"]?.stringValue, "ringing")
        XCTAssertEqual(event.payload["caller_uid"]?.stringValue, "friend-1")
        XCTAssertEqual(event.payload["target_uid"]?.stringValue, "me")
        XCTAssertEqual(event.payload["room_id"]?.stringValue, "room-1")
        XCTAssertEqual(event.payload["channel_id"]?.stringValue, "friend-1:me")
    }

    func testRemoteRTCCallEventPreservesNestedAuthoritativeCallObject() throws {
        let data = """
        {
          "notification_id": "notification-video-1",
          "event": "rtc.call.ringing",
          "call": {
            "id": "call-http-video",
            "status": "ringing",
            "caller_uid": "friend-1",
            "callee_uid": "me",
            "room_id": "room-http-video",
            "channel_id": "friend-1:me",
            "call_type": "video",
            "requested_media_mode": "video",
            "media_mode": "audio"
          }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RemoteRTCCallEvent.self, from: data)
        let call = try XCTUnwrap(event.payload["call"]?.objectValue)

        XCTAssertEqual(event.notificationID, "notification-video-1")
        XCTAssertEqual(event.type, "rtc.call.ringing")
        XCTAssertEqual(call["id"]?.stringValue, "call-http-video")
        XCTAssertEqual(call["call_type"]?.stringValue, "video")
        XCTAssertEqual(call["requested_media_mode"]?.stringValue, "video")
        XCTAssertEqual(call["media_mode"]?.stringValue, "audio")
    }

    func testRemoteRTCCallEventPreservesFlatVideoIntentRevisionAndDevices() throws {
        let data = """
        {
          "notification_id": "notification-flat-video-1",
          "event": "rtc.call.ringing",
          "call_id": "call-flat-video",
          "caller_uid": "friend-1",
          "callee_uid": "me",
          "call_type": "video",
          "requested_media_mode": "video",
          "media_mode": "audio",
          "state_version": 4,
          "caller_device_id": "web-caller",
          "callee_device": { "device_id": "ios-callee" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RemoteRTCCallEvent.self, from: data)

        XCTAssertEqual(event.payload["call_type"]?.stringValue, "video")
        XCTAssertEqual(event.payload["requested_media_mode"]?.stringValue, "video")
        XCTAssertEqual(event.payload["media_mode"]?.stringValue, "audio")
        XCTAssertEqual(event.payload["state_version"]?.stringValue, "4")
        XCTAssertEqual(event.payload["caller_device_id"]?.stringValue, "web-caller")
        XCTAssertEqual(
            event.payload["callee_device"]?.objectValue?["device_id"]?.stringValue,
            "ios-callee"
        )
    }

    @MainActor
    func testNestedRealtimeVideoRingingPreservesRequestedCallType() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [makeUser(id: "friend-1", name: "Friend")]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "rtc_call",
                requestID: "nested-video-ringing",
                payload: [
                    "rtc_call": .object([
                        "event": .string("rtc.call.ringing"),
                        "call_type": .string("audio"),
                        "requested_media_mode": .string("audio"),
                        "call": .object([
                            "id": .string("call-nested-video"),
                            "status": .string("ringing"),
                            "caller_uid": .string("friend-1"),
                            "callee_uid": .string("uid-1"),
                            "room_id": .string("room-nested-video"),
                            "channel_id": .string("friend-1:uid-1"),
                            "call_type": .string("video"),
                            "requested_media_mode": .string("video"),
                            "media_mode": .string("audio")
                        ])
                    ])
                ]
            )
        )

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-nested-video")
        XCTAssertTrue(state.incomingVoiceCall?.isVideo == true)
        XCTAssertEqual(state.incomingVoiceCall?.source, "好友视频通话")
    }

    @MainActor
    func testAcceptedEventForLosingCalleeDeviceEndsOnlyLocalCallWithoutStartingMedia() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.activeVoiceCall = VoiceCallSession(
            id: "loser-local-call",
            callID: "call-device-winner",
            roomID: "room-device-winner",
            peer: caller,
            direction: "来电",
            startedAt: "刚刚",
            statusText: "等待接听",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true
        )

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "rtc.call.accepted",
                requestID: "accepted-on-other-device",
                payload: [
                    "event": .string("rtc.call.accepted"),
                    "call": .object([
                        "id": .string("call-device-winner"),
                        "status": .string("accepted"),
                        "caller_uid": .string("friend-1"),
                        "callee_uid": .string("uid-1"),
                        "call_type": .string("video"),
                        "requested_media_mode": .string("video"),
                        "media_mode": .string("video"),
                        "state_version": .int(2),
                        "delivery_context": .object([
                            "schema": .string("rtc-call-delivery-v1"),
                            "viewer_role": .string("callee"),
                            "viewer_is_bound_participant": .bool(false)
                        ])
                    ])
                ]
            )
        )

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.callID, "call-device-winner")
        XCTAssertEqual(state.calls.first?.status, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.endReason, "answered_elsewhere")
    }

    @MainActor
    func testAcceptedPollingForLosingCalleeDeviceDoesNotStartMedia() throws {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-polled-other-device",
            roomID: "room-polled-other-device",
            mediaMode: "video"
        )

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-polled-other-device",
                status: "accepted",
                roomID: "room-polled-other-device",
                callerUID: "friend-1",
                calleeUID: "uid-1",
                channelID: "friend-1:uid-1",
                channelType: "direct",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                acceptedDevice: RemoteRTCDevice(
                    uid: "uid-1",
                    deviceID: "another-device",
                    deviceType: "ios"
                ),
                stateVersion: 3
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.endReason, "answered_elsewhere")
        XCTAssertEqual(videoClient.startCount, 0)
    }

    func testIncomingCallAdmissionDeduplicatesOneCallAndRejectsSecondWhileBusy() {
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-1",
                isRinging: true,
                presentedCallIDs: []
            ),
            .accept
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-1",
                isRinging: true,
                presentedCallIDs: ["call-1"]
            ),
            .duplicate
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-2",
                isRinging: true,
                presentedCallIDs: ["call-1"]
            ),
            .busy
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: " ",
                isRinging: true,
                presentedCallIDs: []
            ),
            .invalid
        )
    }

    @MainActor
    func testAppStateRTCCallsReconcileShowsRingingWhenTerminalCallIsAlsoReturned() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "陈星")
        let caller = makeUser(id: "WXT00000003", name: "孟瑶")

        state.currentUser = currentUser
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.activeVoiceCall = VoiceCallSession(
            id: "voice-old-call",
            callID: "call-old",
            peer: caller,
            direction: "呼出",
            startedAt: "刚刚",
            isMuted: false,
            speakerOn: true
        )

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-old",
                status: "canceled",
                roomID: "room-old",
                callerUID: "WXT00000002",
                calleeUID: "WXT00000003",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            ),
            RemoteRTCCall(
                id: "call-new",
                status: "ringing",
                roomID: "room-new",
                callerUID: "WXT00000003",
                calleeUID: "WXT00000002",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-new")
        XCTAssertEqual(state.incomingVoiceCall?.caller.id, "WXT00000003")
    }

    @MainActor
    func testAppStateIncomingVoiceCallDuplicateEventKeepsExistingBanner() throws {
        let state = AppState()
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.currentUser = currentUser
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")
        let firstIncomingID = state.incomingVoiceCall?.id

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")

        XCTAssertNotNil(firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.id, firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
    }

    @MainActor
    func testAppStateForegroundCallKitRingtoneStillKeepsOneInAppCallCard() throws {
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["call-1"])
        let state = AppState(voiceCallSystem: system)
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.currentUser = currentUser
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertTrue(system.started)
        XCTAssertTrue(system.hasPresentedCall(callID: "call-1"))
    }

    @MainActor
    func testAppStateForegroundIncomingVoiceCallUsesInAppPresentationWithoutCallKit() throws {
        let system = TestVoiceCallSystemIntegration()
        let state = AppState(voiceCallSystem: system, apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.currentUser = currentUser
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1", roomID: "room-1")

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertFalse(state.incomingVoiceCall?.isVideo ?? true)
        XCTAssertTrue(system.reportedPayloads.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: "call-1"))
    }

    func testAppStateForegroundVideoCallUsesInAppPresentationWithoutCallKit() throws {
        let system = TestVoiceCallSystemIntegration()
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            voiceCallSystem: system,
            apiContextOverride: makeIsolatedAPIContext()
        )
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.currentUser = currentUser
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(
            maxBytes: 20 * 1024 * 1024,
            maxMB: 20,
            source: "test",
            messageRecallMaxMinutes: 120,
            voiceCallEnabled: true,
            videoCallEnabled: true,
            readReceiptsEnabled: true,
            groupAdminDeleteMessageEnabled: false
        )

        state.receiveIncomingVoiceCall(
            from: friend,
            callID: "video-call-1",
            roomID: "video-room-1",
            mediaMode: "video"
        )

        XCTAssertEqual(state.incomingVoiceCall?.callID, "video-call-1")
        XCTAssertTrue(state.incomingVoiceCall?.isVideo ?? false)
        XCTAssertTrue(system.reportedPayloads.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: "video-call-1"))
    }

    @MainActor
    func testSecondIncomingCallRejectsServerExactlyOnceWhileFirstCallRemainsVisible() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = makeCallEndingAPI(transport: transport)
        let system = TestVoiceCallSystemIntegration(
            presentedCallIDs: ["call-first", "call-second"]
        )
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/call-second/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/call-second/reject"), 1)
        XCTAssertEqual(system.endedCalls.map(\.callID), ["call-second"])
        XCTAssertEqual(system.endedCalls.map(\.reason), ["client_busy"])
        XCTAssertTrue(system.hasPresentedCall(callID: "call-first"))
        XCTAssertFalse(system.hasPresentedCall(callID: "call-second"))
    }

    @MainActor
    func testTerminalCompensationFailuresDoNotScheduleOtherInFlightCalls() async throws {
        let a = "/api/rtc/calls/call-a/reject"
        let b = "/api/rtc/calls/call-b/reject"
        let transport = RTCSystemEndHTTPTransport(
            remainingFailuresByPath: [a: 1000, b: 1000],
            failureDelayNanoseconds: 1_000_000
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            rtcTerminalCompensationFailureDelayNanoseconds: [500_000_000],
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        defer { state.clearRTCTerminalCompensationsForTesting() }
        let first = makeUser(id: "friend-first")
        let other = makeUser(id: "friend-other")
        state.currentUser = makeUser(id: "uid-1")
        state.contacts = [first, other]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: other, callID: "call-a")
        state.receiveIncomingVoiceCall(from: other, callID: "call-b")
        for _ in 0..<100 where state.rtcTerminalCompensationsInFlightCountForTesting > 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 0)
        let before = transport.requestCount(path: a) + transport.requestCount(path: b)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(before, 2)
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount(path: a) + transport.requestCount(path: b), before)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        // Refresh/retry triggers before nextAttemptAt must not bypass the independent backoff timer.
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        state.retryPendingRTCTerminalCompensationsForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 0)
        XCTAssertEqual(transport.requestCount(path: a) + transport.requestCount(path: b), before)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
    }

    @MainActor
    func testBusyRejectTerminalCompensationRetriesAfterTransportRecoveryAndClearsIntent() async throws {
        let path = "/api/rtc/calls/call-second/reject"
        let transport = RTCSystemEndHTTPTransport(
            remainingFailuresByPath: [path: 1],
            failureDelayNanoseconds: 50_000_000
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            rtcTerminalCompensationFailureDelayNanoseconds: [10_000_000],
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        defer { state.clearRTCTerminalCompensationsForTesting() }
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: path) == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 1)
        await state.refreshRTCCallsForTesting()
        for _ in 0..<100 where transport.requestCount(path: path) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: path), 2)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        let keys = transport.idempotencyKeys(path: path)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1)
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
    }

    @MainActor
    func testTerminalCompensationScopeResetDropsOldIntentAndPreventsRetry() async throws {
        let path = "/api/rtc/calls/call-second/reject"
        let transport = RTCSystemEndHTTPTransport(remainingFailuresByPath: [path: 10])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: path) == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.clearRTCTerminalCompensationsForTesting()
        state.retryPendingRTCTerminalCompensationsForTesting()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
        XCTAssertEqual(transport.requestCount(path: path), 1)
    }

    @MainActor
    func testCallKitPresentedVideoAdmissionFailureEndsSystemCallAndRejectsServerOnce() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["video-unavailable"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "video-unavailable",
            mediaMode: "video",
            systemOwnsRingtone: true
        )
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-unavailable/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertFalse(system.hasPresentedCall(callID: "video-unavailable"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-unavailable/reject"), 1)
    }

    @MainActor
    func testCallKitAnswerProviderFailureRollsBackSystemAndRejectsServerCall() async throws {
        for videoAsAudio in [false, true] {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["answer-failure"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "answer-failure",
            roomID: "answer-room",
            systemOwnsRingtone: true
        )
        if videoAsAudio {
            state.incomingVoiceCall = IncomingVoiceCall(id: "answer-failure", callID: "answer-failure",
                caller: caller, startedAt: "刚刚", source: "系统视频来电", requestedMediaMode: "video")
        }

        state.handleVoiceCallSystemEventForTesting(.answer(callID: "answer-failure"))
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/answer-failure/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(system.hasPresentedCall(callID: "answer-failure"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/answer-failure/reject"), 1)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/answer-failure/accept"), 0)
        }
    }

    @MainActor
    func testAcceptedVideoCallOnColdLaunchAuthoritativelyTerminatesWhenResumeIsUnsupported() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["accepted-video"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.currentUser = makeUser(id: "uid-1", name: "Me")

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "accepted-video",
                status: "accepted",
                roomID: "room-accepted-video",
                callerUID: "uid-1",
                calleeUID: "friend-1",
                channelID: "uid-1:friend-1",
                channelType: "direct",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                callerDevice: RemoteRTCDevice(uid: "uid-1", deviceID: "unit-test-device", deviceType: "ios"),
                acceptedDevice: RemoteRTCDevice(uid: "friend-1", deviceID: "peer-device", deviceType: "ios"),
                stateVersion: 9
            )
        ])
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/accepted-video/hangup") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "视频通话因应用重启已安全结束")
        XCTAssertFalse(system.hasPresentedCall(callID: "accepted-video"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/accepted-video/hangup"), 1)
    }

    @MainActor
    func testOutgoingVideoRingingOnColdLaunchIsCanceledExactlyOnce() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["ringing-video"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.currentUser = makeUser(id: "uid-1", name: "Me")

        let remote = RemoteRTCCall(
            id: "ringing-video",
            status: "ringing",
            roomID: "room-ringing-video",
            callerUID: "uid-1",
            calleeUID: "friend-1",
            channelID: "uid-1:friend-1",
            channelType: "direct",
            callType: "video",
            requestedMediaMode: "video",
            mediaMode: "video",
            callerDevice: RemoteRTCDevice(uid: "uid-1", deviceID: "unit-test-device", deviceType: "ios"),
            stateVersion: 3
        )
        state.reconcileRTCCallsForTesting([remote])
        state.reconcileRTCCallsForTesting([remote])
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/ringing-video/cancel") == 0
            || state.pendingRTCTerminalCompensationCountForTesting != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.toast, "视频呼叫因应用重启已安全取消")
        XCTAssertFalse(system.hasPresentedCall(callID: "ringing-video"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/ringing-video/cancel"), 1)
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
    }

    @MainActor
    func testVideoMediaFailureEndsLocalCallAndCompensatesServerHangup() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-failure",
            callID: "video-media-failure",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true
        )

        state.handleVideoMediaEvent(.failed, callID: "video-media-failure")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-media-failure/hangup") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "视频通话连接失败")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-media-failure/hangup"), 1)
    }

    @MainActor
    func testVideoAudioLifecycleReconciliationSurfacesFailureWithoutChangingCallState() async throws {
        let videoClient = TestVideoMediaClient()
        videoClient.audioReconcileError = IMAPIError.server("route failed")
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-audio-local",
            callID: "video-audio-reconcile",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video"
        )

        state.reconcileActiveVideoAudioSessionForTesting(reason: "media_services_reset")
        for _ in 0..<20 where videoClient.audioReconcileCount == 0 { await Task.yield() }

        XCTAssertEqual(videoClient.audioReconcileCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-audio-reconcile")
        XCTAssertEqual(state.toast, "视频通话音频服务恢复失败，请结束后重试")
    }

    @MainActor
    func testVoiceAudioLifecycleReconciliationUsesVoiceMediaClient() async throws {
        let voiceClient = TestVoiceMediaClient()
        let state = AppState(
            voiceMediaClient: voiceClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "voice-audio-local",
            callID: "voice-audio-reconcile",
            peer: makeUser(id: "friend-voice", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: false
        )

        state.reconcileActiveVideoAudioSessionForTesting(reason: "route_changed")
        for _ in 0..<20 where voiceClient.audioReconcileSpeakerValues.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(voiceClient.audioReconcileSpeakerValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.callID, "voice-audio-reconcile")
    }

    func testVideoRendererContractRebindsTracksObservesFirstFrameAndDetachesOnClose() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("BlueStoneIM/VideoMediaClient.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("localRenderers.values.forEach { old.remove($0) }"))
        XCTAssertTrue(source.contains("remoteRenderers.values.forEach { old.remove($0) }"))
        XCTAssertTrue(source.contains("remoteVideoTrack.remove(remoteFirstFrameObserver)"))
        XCTAssertTrue(source.contains("self.emit(.remoteVideoTrackReady)"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.setRemoteTrack(track)"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.clear()"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.setRemoteTrack(nil)"))
    }

    func testVideoCallAccessibilityAndPrivacyUsageDescriptionsRemainReleaseReady() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let videoViews = try String(
            contentsOf: sourceRoot.appendingPathComponent("BlueStoneIM/VideoCallViews.swift"),
            encoding: .utf8
        )
        let incomingViews = try String(
            contentsOf: sourceRoot.appendingPathComponent("BlueStoneIM/FilesRTCViews.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: sourceRoot.appendingPathComponent("BlueStoneIM/BlueStoneIMApp.swift"),
            encoding: .utf8
        )
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: sourceRoot.appendingPathComponent("BlueStoneIM/Info.plist"))
        )

        for identifier in [
            "video_call_peer_profile_disabled",
            "video_call_mute_button",
            "video_call_camera_button",
            "video_call_switch_camera_button",
            "video_call_speaker_button",
            "video_call_end_button"
        ] {
            XCTAssertTrue(videoViews.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
        for identifier in ["incoming_call_reject_button", "incoming_voice_answer_button",
                           "incoming_video_answer_audio_button", "incoming_video_answer_video_button"] {
            XCTAssertTrue(incomingViews.contains("\"\(identifier)\""), identifier)
        }
        XCTAssertTrue(incomingViews.contains(".accessibilityIdentifier(identifier)"))
        XCTAssertTrue(app.contains("overlayWindow?.frame = scene.coordinateSpace.bounds"))
        XCTAssertTrue(app.contains("view.accessibilityViewIsModal = true"))
        XCTAssertFalse(app.contains("IncomingVoiceCallBanner("))
        XCTAssertFalse(app.contains("IncomingVideoCallOverlay("))
        XCTAssertTrue((plist["NSMicrophoneUsageDescription"] as? String)?.contains("视频通话") == true)
        XCTAssertTrue((plist["NSCameraUsageDescription"] as? String)?.contains("视频通话") == true)
        let backgroundModes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])
        XCTAssertTrue(backgroundModes.contains("audio"))
        XCTAssertTrue(backgroundModes.contains("voip"))
        XCTAssertTrue(backgroundModes.contains("remote-notification"))
    }

    func testVideoCameraFailurePolicyNeverRestartsCameraAfterDisableFailure() {
        XCTAssertFalse(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: false,
                previousIntent: true
            )
        )
        XCTAssertFalse(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: true,
                previousIntent: false
            )
        )
        XCTAssertTrue(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: true,
                previousIntent: true
            )
        )
    }

    @MainActor
    func testActiveVideoCallBackgroundLifecyclePreservesCallWhilePausingVideoCapture() async {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-background-local",
            callID: "video-background-call",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.handleVideoApplicationDidEnterBackground()
        for _ in 0..<20 where videoClient.backgroundCount == 0 { await Task.yield() }

        XCTAssertEqual(videoClient.backgroundCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-background-call")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
    }

    @MainActor
    func testVideoSpeakerAndCameraControlsUpdateImmediatelyAndRollbackOnMediaFailure() async throws {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.voiceMediaClientAvailableOverride = true
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local",
            callID: "video-controls",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            cameraPosition: .front
        )

        state.toggleActiveCallSpeaker()
        XCTAssertEqual(state.activeVoiceCall?.speakerOn, false)
        for _ in 0..<20 where videoClient.speakerValues.isEmpty { await Task.yield() }
        XCTAssertEqual(videoClient.speakerValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.speakerOn, false)

        videoClient.cameraError = IMAPIError.server("camera failed")
        state.toggleActiveVideoCamera()
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        for _ in 0..<20 where videoClient.cameraValues.isEmpty { await Task.yield() }
        XCTAssertEqual(videoClient.cameraValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, true)

        videoClient.switchCameraError = IMAPIError.server("switch failed")
        state.switchActiveVideoCamera()
        XCTAssertEqual(state.activeVoiceCall?.cameraPosition, .back)
        for _ in 0..<20 where videoClient.switchCameraCount == 0 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.cameraPosition, .front)
        XCTAssertEqual(state.toast, "切换摄像头失败，已保留原摄像头")

        videoClient.foregroundError = IMAPIError.server("foreground resume failed")
        state.handleVideoApplicationWillEnterForeground()
        for _ in 0..<20 where videoClient.foregroundCount == 0 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.toast, "返回前台后摄像头恢复失败，已保持关闭")
    }

    @MainActor
    func testVideoDowngradeUsesExistingEndpointAndAppliesAudioMode() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local",
            callID: "video-downgrade",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方连接",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            remoteVideoTrackReady: true
        )

        state.downgradeActiveVideoCallToAudio()
        XCTAssertEqual(state.activeVoiceCall?.statusText, "正在切换为语音通话")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-downgrade/downgrade") == 0
            || videoClient.downgradeToAudioCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-downgrade/downgrade"), 1)
        XCTAssertEqual(videoClient.downgradeToAudioCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "等待对方连接")
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteVideoTrackReady, false)
        XCTAssertEqual(state.toast, "已切换为语音通话，当前通话无法恢复视频")
    }

    @MainActor
    func testAppStateIgnoresSystemEndForInAppPollingCallNotPresentedByCallKit() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration()
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: caller, callID: "polling-call", roomID: "polling-room")

        state.handleVoiceCallSystemEventForTesting(.end(callID: "polling-call", reason: "callkit_end"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.incomingVoiceCall?.callID, "polling-call")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/polling-call/reject"), 0)
        XCTAssertTrue(system.endedCalls.isEmpty)
    }

    @MainActor
    func testAppStateSystemEndRejectsCallActuallyPresentedByCallKit() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["push-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )

        state.handleVoiceCallSystemEventForTesting(.end(callID: "push-call", reason: "callkit_end"))
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/push-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/push-call/reject"), 1)
        XCTAssertFalse(system.hasPresentedCall(callID: "push-call"))
    }

    @MainActor
    func testCallKitProviderResetTerminatesServerSuppressesSameCallAndAllowsNextIncomingCall() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["reset-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let currentUser = makeUser(id: "uid-1", name: "Me")
        let firstCaller = makeUser(id: "friend-1", name: "Friend One")
        let nextCaller = makeUser(id: "friend-2", name: "Friend Two")
        state.currentUser = currentUser
        state.contacts = [firstCaller, nextCaller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(
            from: firstCaller,
            callID: "reset-call",
            roomID: "reset-room",
            systemOwnsRingtone: true
        )

        state.handleVoiceCallSystemEventForTesting(.providerReset)

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "系统通话服务已重置，通话已结束")

        state.receiveIncomingVoiceCall(
            from: firstCaller,
            callID: "reset-call",
            roomID: "reset-room"
        )
        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "reset-call",
                status: "ringing",
                roomID: "reset-room",
                callerUID: "friend-1",
                calleeUID: "uid-1",
                channelID: "friend-1:uid-1",
                channelType: "direct",
                callType: "audio"
            )
        ])
        XCTAssertNil(state.incomingVoiceCall, "A provider-reset terminal call must not resurrect from push or polling")

        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/reset-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/reset-call/reject"), 1)

        state.receiveIncomingVoiceCall(
            from: nextCaller,
            callID: "next-call",
            roomID: "next-room"
        )
        XCTAssertEqual(state.incomingVoiceCall?.callID, "next-call")
    }

    @MainActor
    func testCallKitProviderResetCleansLifecycleOnlyIncomingAndRejectsServerCall() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["lifecycle-only-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "lifecycle-only-call",
            roomID: "lifecycle-only-room",
            systemOwnsRingtone: true
        )
        state.incomingVoiceCall = nil

        state.handleVoiceCallSystemEventForTesting(.providerReset)

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "系统通话服务已重置，通话已结束")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/lifecycle-only-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/lifecycle-only-call/reject"), 1)

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "lifecycle-only-call",
            roomID: "lifecycle-only-room"
        )
        XCTAssertNil(state.incomingVoiceCall)
    }

    @MainActor
    func testAppStateVoIPTerminalPayloadCannotDirectlyEndCallKitCall() throws {
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["call-1"])
        let state = AppState(voiceCallSystem: system)
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "cancel",
            "call_id": "call-1",
            "room_id": "room-1",
            "caller_uid": "friend-1",
            "callee_uid": "me",
            "caller_name": "Friend",
            "call_type": "audio",
            "provider": "self_hosted_webrtc"
        ]))

        state.currentUser = currentUser
        state.contacts = [friend]
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-1",
            callID: "call-1",
            caller: friend,
            startedAt: "刚刚",
            source: "好友语音通话"
        )

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(payload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertTrue(system.endedCalls.isEmpty)
    }

    @MainActor
    func testAppStateIncomingVoiceCallDuplicateEventRefreshesGenericCallerProfile() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let genericCaller = makeUser(id: "WXT00000003", name: "语音联系人")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2"
        )

        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: genericCaller, callID: "call-1")
        let firstIncomingID = state.incomingVoiceCall?.id

        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.id, firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
    }

    @MainActor
    func testAppStateIncomingCallDuplicateHigherRevisionCorrectsAudioToVideoWithoutDowngrade() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let caller = makeUser(id: "WXT00000003", name: "Meng")
        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "audio",
            stateVersion: 1
        )
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "video",
            stateVersion: 2
        )
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "audio",
            stateVersion: 1
        )

        XCTAssertTrue(state.incomingVoiceCall?.isVideo == true)
        XCTAssertEqual(state.incomingVoiceCall?.source, "好友视频通话")
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
    }

    @MainActor
    func testAppStateIncomingVoiceCallRefreshesGenericCallerAcrossServerAndIMIDs() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let genericServerCaller = makeUser(id: "server-user-3", name: "语音联系人")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2"
        )

        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: genericServerCaller, callID: "call-1")
        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.caller.id, "WXT00000003")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
    }

    @MainActor
    func testAppStateVoIPPushAvatarHydratesIncomingCall() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-1",
            "room_id": "room-avatar-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "https://example.test/voice-avatar.png",
            "caller_avatar_version": "voice-v1",
            "caller_avatar_updated_at": "2026-06-26T04:00:00Z",
            "call_type": "audio"
        ]))

        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(payload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-avatar-1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/voice-avatar.png")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "voice-v1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarUpdatedAt, "2026-06-26T04:00:00Z")
    }

    @MainActor
    func testAppStateRTCBareRefreshDoesNotClearKnownIncomingAvatar() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "2026-06-26T04:05:00Z"
        )

        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-1",
                status: "ringing",
                roomID: "room-1",
                callerUID: "WXT00000003",
                calleeUID: "WXT00000002",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            )
        ])

        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "v2")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarUpdatedAt, "2026-06-26T04:05:00Z")
    }

    @MainActor
    func testAppStateNextVoIPCallWithoutAvatarDoesNotReusePreviousAvatar() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let firstPayload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "https://example.test/voice-avatar.png",
            "caller_avatar_version": "voice-v1",
            "call_type": "audio"
        ]))
        let secondPayload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-2",
            "caller_uid": "WXT00000004",
            "callee_uid": "WXT00000002",
            "caller_name": "李雷",
            "call_type": "audio"
        ]))

        state.currentUser = currentUser
        state.voiceMediaClientAvailableOverride = true

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(firstPayload))
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/voice-avatar.png")
        state.incomingVoiceCall = nil

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(secondPayload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-avatar-2")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "李雷")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "")
    }

    @MainActor
    func testAppStateDisplayUserForVoiceCallResolvesGenericCallerFromDirectConversation() throws {
        let state = AppState()
        let genericCaller = makeUser(id: "WXT00000003", name: "语音联系人")
        var direct = makeConversation(
            id: "WXT00000002:WXT00000003",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        direct.title = "孟瑶"
        direct.avatarURL = "https://example.test/direct-avatar.png"
        direct.avatarVersion = "v3"

        state.currentUser = makeUser(id: "WXT00000002", name: "陈星")
        state.conversationStore.conversations = [direct]

        let displayUser = state.displayUserForVoiceCall(genericCaller)

        XCTAssertEqual(displayUser.id, "WXT00000003")
        XCTAssertEqual(displayUser.name, "孟瑶")
        XCTAssertEqual(displayUser.avatarURL, "https://example.test/direct-avatar.png")
    }

    @MainActor
    func testAppStateDisplayUserForVoiceCallResolvesAvatarByUsername() throws {
        let state = AppState()
        let contact = IMUser(
            id: "339330",
            userID: "WXT88188660",
            username: "admin11",
            name: "美死了",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "",
            avatarSeed: 0,
            avatarURL: "https://example.test/admin11.png",
            avatarVersion: "v11",
            avatarUpdatedAt: "2026-07-01T12:00:00Z",
            badges: []
        )
        let callerFromPayload = makeUser(id: "admin11", name: "语音联系人")

        state.currentUser = makeUser(id: "self", name: "Me")
        state.contacts = [contact]

        let displayUser = state.displayUserForVoiceCall(callerFromPayload)

        XCTAssertEqual(displayUser.id, "339330")
        XCTAssertEqual(displayUser.name, "美死了")
        XCTAssertEqual(displayUser.avatarURL, "https://example.test/admin11.png")
        XCTAssertEqual(displayUser.avatarVersion, "v11")
        XCTAssertEqual(displayUser.avatarUpdatedAt, "2026-07-01T12:00:00Z")
    }

    @MainActor
    func testVoiceMediaEventsGateConnectedAtUntilTransportAndTrackReady() throws {
        let state = AppState()
        let peer = makeUser(id: "peer-1", name: "Peer")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let connectedAt = Date(timeIntervalSince1970: 1_030)
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "https://rtc.example.test",
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方接听",
            mediaState: .preparing,
            isMuted: false,
            speakerOn: true,
            startedAtDate: startedAt,
            connectedAt: nil
        )

        state.handleVoiceMediaEvent(.callAccepted, callID: "call-1", now: startedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .preparing)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "连接中")
        XCTAssertNil(state.activeVoiceCall?.connectedAt)

        state.handleVoiceMediaEvent(.roomJoined, callID: "call-1", now: startedAt)
        state.handleVoiceMediaEvent(.localDescriptionSet, callID: "call-1", now: startedAt)
        state.handleVoiceMediaEvent(.iceChecking, callID: "call-1", now: startedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connecting)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "连接中")
        XCTAssertNil(state.activeVoiceCall?.connectedAt)

        state.handleVoiceMediaEvent(.iceConnected, callID: "call-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "call-1", now: Date(timeIntervalSince1970: 1_031))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: "call-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.callAccepted, callID: "call-1", now: Date(timeIntervalSince1970: 1_060))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "call-1", now: Date(timeIntervalSince1970: 1_061))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)
    }

    @MainActor
    func testIncomingVideoAnsweredAsAudioAcceptsVoiceMediaConnectedEvent() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-video-audio-connected"
        let peer = makeUser(id: "incoming-video-audio-peer", name: "Video Peer")
        let voiceMediaClient = TestVoiceMediaClient(
            events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady]
        )
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "video",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: voiceMediaClient,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-audio",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await joinGate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await joinGate.resumeFirst()
        for _ in 0..<200 where state.activeVoiceCall?.mediaState != .connected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, callID)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.requestedMediaMode, "video")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.callID, callID)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerUID, peer.id)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerDeviceID, "peer-device")
        XCTAssertNotEqual(
            voiceMediaClient.startedContexts.first?.peerDeviceID,
            voiceMediaClient.startedContexts.first?.localDeviceID
        )
        state.endActiveVoiceCall()
        for _ in 0..<100 where voiceMediaClient.stopReasons.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(voiceMediaClient.stopReasons, ["user_ending"])
        state.activeVoiceCall = nil // End the isolated fixture after verifying immediate capture cleanup.

    }

    @MainActor
    func testIncomingAudioStartsHeartbeatThroughRealAcceptAndJoin() async throws {
        for invalidator in ["account", "device", "epoch", "end", "license"] {
            let joinGate = FirstJoinSuspensionGate()
            let callID = "incoming-audio-connected-\(invalidator)"
            let peer = makeUser(id: "incoming-audio-peer", name: "Video Peer")
            let voiceMediaClient = TestVoiceMediaClient(
                events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady]
            )
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID,
                callType: "audio",
                peerUID: peer.id,
                firstJoinGate: joinGate
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: voiceMediaClient,
                videoMediaClient: TestVideoMediaClient(),
                microphonePermissionDecisionOverride: { true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.isAuthenticated = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(
                id: "incoming-audio",
                callID: callID,
                caller: peer,
                startedAt: "刚刚",
                source: "好友视频通话",
                requestedMediaMode: "audio"
            )

            state.acceptIncomingVoiceCall()
            for _ in 0..<200 {
                if await joinGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await joinGate.resumeFirst()
            for _ in 0..<200 where state.activeVoiceCall?.mediaState != .connected {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, callID)
            defer { state.stopRTCMediaStateHeartbeatForTesting() }
            XCTAssertEqual(state.activeVoiceCall?.callID, callID)
            XCTAssertEqual(state.activeVoiceCall?.requestedMediaMode, "audio")
            XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
            XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
            XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
            XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
            let heartbeat = try XCTUnwrap(state.rtcMediaHeartbeatSnapshotForTesting)
            let operationID = try XCTUnwrap(heartbeat.operationID)
            let savedContext = try XCTUnwrap(voiceMediaClient.startedContexts.first)
            let signalPath = "/api/rtc/rooms/\(callID)-room/signals"
            let icePath = "/api/rtc/rooms/\(callID)-room/ice-credentials"
            _ = try await savedContext.pollSignals("", "rtc-token-before-refresh")
            state.updateRTCMediaHeartbeatContextForTesting { $0.imToken = "refreshed-im-token" }
            _ = try await savedContext.pollSignals("", "rtc-token-after-refresh")
            let refreshedIce = try await savedContext.refreshIceCredentials("rtc-token-after-refresh")
            XCTAssertEqual(refreshedIce.rtcToken, "rtc-refreshed")
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.context.imToken, "refreshed-im-token")
            XCTAssertEqual(transport.requestCount(path: signalPath), 2)
            XCTAssertEqual(transport.requestCount(path: icePath), 1)
            XCTAssertEqual(transport.authorizationHeader(path: signalPath), "Bearer rtc-token-after-refresh")
            XCTAssertEqual(transport.authorizationHeader(path: icePath), "Bearer rtc-token-after-refresh")

            state.handleVoiceMediaEvent(.iceDisconnected, callID: callID, operationID: operationID)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.generation, heartbeat.generation)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "reconnecting")
            state.handleVoiceMediaEvent(.connectionRecovered, callID: callID, operationID: operationID)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "reconnecting")
            state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: callID, operationID: operationID)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "connected")
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.callID, callID)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerUID, peer.id)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerDeviceID, "peer-device")
            XCTAssertNotEqual(
                voiceMediaClient.startedContexts.first?.peerDeviceID,
                voiceMediaClient.startedContexts.first?.localDeviceID
            )
            switch invalidator {
            case "account": state.updateRTCMediaHeartbeatContextForTesting { $0.accountID = "replacement-account" }
            case "device": state.updateRTCMediaHeartbeatContextForTesting { $0.deviceID = "replacement-device" }
            case "epoch": state.updateRTCMediaHeartbeatContextForTesting { $0.sessionEpoch = "replacement-epoch" }
            case "end": state.endActiveVoiceCall()
            default: state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            }
            do {
                _ = try await savedContext.pollSignals("", "rtc-token-after-refresh")
                XCTFail("Old poll closure must be rejected after \(invalidator)")
            } catch is CancellationError {} catch { XCTFail("Unexpected poll error: \(error)") }
            do {
                _ = try await savedContext.refreshIceCredentials("rtc-token-after-refresh")
                XCTFail("Old ICE closure must be rejected after \(invalidator)")
            } catch is CancellationError {} catch { XCTFail("Unexpected ICE error: \(error)") }
            XCTAssertEqual(transport.requestCount(path: signalPath), 2, invalidator)
            XCTAssertEqual(transport.requestCount(path: icePath), 1, invalidator)
            state.activeVoiceCall = nil
        }

    }

    @MainActor
    func testIncomingAudioRetriesReceiverMediaStartBeforeEndingCall() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-audio-start-retry"
        let peer = makeUser(id: "incoming-audio-retry-peer", name: "Audio Peer")
        let voiceMediaClient = TestVoiceMediaClient(
            events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady],
            startErrors: [IMAPIError.server("音频设备启动暂不可用")]
        )
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "audio",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: voiceMediaClient,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-audio-retry",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话",
            requestedMediaMode: "audio"
        )

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await joinGate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await joinGate.resumeFirst()
        for _ in 0..<300 {
            if voiceMediaClient.startedContexts.count == 2,
               state.activeVoiceCall?.mediaState == .connected {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(voiceMediaClient.startedContexts.count, 2)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
        XCTAssertEqual(voiceMediaClient.startedContexts.last?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertNotEqual(state.toast, Optional("音频设备启动失败，通话已结束"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/hangup"), 0)

        state.endActiveVoiceCall()
        for _ in 0..<100 where voiceMediaClient.stopReasons.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(voiceMediaClient.stopReasons, ["user_ending"])
        state.activeVoiceCall = nil
    }

    func testVideoCallPreviewShowsStartingStateRejectsDuplicateAndSurfacesProviderFailure() async throws {
        let routeDefaultsName = "BlueStoneIMTests.video-provider-route.\(UUID().uuidString)"
        let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: routeDefaultsName))
        defer { routeDefaults.removePersistentDomain(forName: routeDefaultsName) }
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 503
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )
        XCTAssertEqual(
            api.activateRuntimeRoutesForTesting(try videoCallRuntimeRouteSnapshot()),
            .applied
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        state.isAuthenticated = true
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.videoCallPreview = VideoCallPreview(
            id: "preview-provider-failure",
            peer: peer,
            channelID: "peer-video:uid-1",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: "摄像头暂不可用，可关闭摄像头继续"
        )

        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertTrue(state.videoCallPreview?.isStartingCall ?? false)
        XCTAssertNil(state.videoCallPreview?.startError)

        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertNil(state.videoCallPreview?.startError)

        let deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while state.isStartingVideoCall,
              DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds {
            await Task.yield()
        }

        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertFalse(state.videoCallPreview?.isStartingCall ?? true)
        XCTAssertNotNil(state.videoCallPreview)
        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 1)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 1)
        XCTAssertEqual(state.videoCallPreview?.startError, "视频服务暂不可用，请稍后重试")
        XCTAssertNil(state.toast)
    }

    func testVideoCallPreviewScopeChangeReliablyClearsStartingWithoutPollutingNextGeneration() async throws {
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 150_000_000,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        state.isAuthenticated = true
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.contacts = [peer]
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.videoCallPreview = VideoCallPreview(
            id: "preview-scope-change",
            peer: peer,
            channelID: "peer-video:uid-1",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: "摄像头暂不可用，可关闭摄像头继续"
        )

        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        var changedContext = makeAuthenticatedAPIContext()
        changedContext.tenantID = "tenant-2"
        changedContext.imUID = "uid-2"
        changedContext.imToken = "im-token-2"
        state.overrideAPIContextForTesting(changedContext)

        for _ in 0..<80 where state.isStartingVideoCall {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertFalse(state.videoCallPreview?.isStartingCall ?? true)
        XCTAssertEqual(state.videoCallPreview?.startError, "登录状态已变化，请重新打开视频通话")
        XCTAssertNil(state.activeVoiceCall)

        state.overrideAPIContextForTesting(makeAuthenticatedAPIContext())
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.videoCallPreview = VideoCallPreview(
            id: "preview-next-generation",
            peer: peer,
            channelID: "peer-video:uid-1",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )
        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertTrue(state.videoCallPreview?.isStartingCall ?? false)
        state.dismissVideoCallPreview()
        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertNil(state.videoCallPreview)
    }

    func testEnabledVideoConfigReportsCapabilitiesOncePerAuthenticatedSession() async throws {
        let transport = RTCDeviceCapabilityBootstrapHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true

        state.refreshFileUploadConfig()
        await waitForRequestCount(1, path: "/api/rtc/device-capabilities", transport: transport)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)
        let firstBody = try XCTUnwrap(transport.lastJSONBody(path: "/api/rtc/device-capabilities"))
        let capabilities = try XCTUnwrap(firstBody["device_capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["version"] as? String, RTCDeviceCapabilities.protocolVersion)
        XCTAssertEqual(capabilities["audio"] as? Bool, true)
        XCTAssertEqual(capabilities["video"] as? Bool, true)
        XCTAssertEqual(capabilities["camera_available"] as? Bool, true)

        state.refreshFileUploadConfig()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)

        var nextSession = makeAuthenticatedAPIContext()
        nextSession.tenantID = "tenant-2"
        nextSession.imUID = "uid-2"
        nextSession.imToken = "im-token-2"
        state.overrideAPIContextForTesting(nextSession)
        state.refreshFileUploadConfig()
        await waitForRequestCount(2, path: "/api/rtc/device-capabilities", transport: transport)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 2)
    }

    func testVideoCapabilityBootstrapFailureDoesNotBlockConfigOrSurfaceToast() async throws {
        let transport = RTCDeviceCapabilityBootstrapHTTPTransport(capabilityStatusCode: 503)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true

        state.refreshFileUploadConfig()
        await waitForRequestCount(1, path: "/api/rtc/device-capabilities", transport: transport)

        XCTAssertTrue(state.fileUploadConfig.videoCallEnabled)
        XCTAssertNil(state.toast)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)
    }

    func testVideoMediaEventsGateTimingOnRemoteAudioAndTrackRemoteCameraState() {
        let state = AppState(videoMediaClient: NoopVideoMediaClient())
        let connectedAt = Date(timeIntervalSince1970: 2_030)
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-1",
            callID: "video-1",
            roomID: "room-video-1",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.handleVideoMediaEvent(.mediaConnected, callID: "video-1", now: connectedAt)
        XCTAssertNil(state.activeVoiceCall?.connectedAt)
        state.handleVideoMediaEvent(.remoteAudioTrackReady, callID: "video-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVideoMediaEvent(.remoteCameraPaused, callID: "video-1")
        XCTAssertFalse(state.activeVoiceCall?.remoteCameraEnabled ?? true)
        XCTAssertFalse(state.activeVoiceCall?.remoteVideoTrackReady ?? true)
        state.handleVideoMediaEvent(.remoteCameraResumed, callID: "video-1")
        XCTAssertTrue(state.activeVoiceCall?.remoteCameraEnabled ?? false)
        XCTAssertFalse(state.activeVoiceCall?.remoteVideoTrackReady ?? true)
        state.handleVideoMediaEvent(.remoteVideoTrackReady, callID: "video-1")
        XCTAssertTrue(state.activeVoiceCall?.remoteVideoTrackReady ?? false)

        state.handleVideoMediaEvent(.cameraUnavailable, callID: "video-1")
        XCTAssertFalse(state.activeVoiceCall?.localCameraEnabled ?? true)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.toast, "摄像头暂不可用，已关闭摄像头继续视频通话")

        state.handleVideoMediaEvent(.reconnecting, callID: "video-1", now: connectedAt.addingTimeInterval(10))
        XCTAssertTrue(state.activeVoiceCall?.isRecoveringNetwork ?? false)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "网络不稳定，正在恢复")
        state.handleVideoMediaEvent(.connectionRecovered, callID: "video-1", now: connectedAt.addingTimeInterval(15))
        XCTAssertFalse(state.activeVoiceCall?.isRecoveringNetwork ?? true)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        state.handleVideoMediaEvent(.mediaConnected, callID: "video-1", now: connectedAt.addingTimeInterval(20))
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)
    }

    func testIncomingVideoAnswerPlanKeepsVideoSessionWhenCameraUnavailable() {
        let unavailable = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "video",
            cameraAvailable: false,
            cameraAuthorized: false
        )
        XCTAssertEqual(unavailable.acceptedMode, "video")
        XCTAssertTrue(unavailable.startsVideoMedia)
        XCTAssertFalse(unavailable.cameraEnabled)
        XCTAssertEqual(unavailable.notice, "摄像头暂不可用，已关闭摄像头继续视频通话")

        let authorized = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "video",
            cameraAvailable: true,
            cameraAuthorized: true
        )
        XCTAssertEqual(authorized.acceptedMode, "video")
        XCTAssertTrue(authorized.startsVideoMedia)
        XCTAssertTrue(authorized.cameraEnabled)
        XCTAssertNil(authorized.notice)

        let audio = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "audio",
            cameraAvailable: true,
            cameraAuthorized: true
        )
        XCTAssertEqual(audio.acceptedMode, "audio")
        XCTAssertFalse(audio.startsVideoMedia)
        XCTAssertFalse(audio.cameraEnabled)
        XCTAssertNil(audio.notice)
    }

    func testVideoCallPreviewControlsKeepUnavailableCameraStateTruthful() {
        let unavailable = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: true,
            isPreparing: false,
            isStartingCall: false,
            unavailableReason: "摄像头暂不可用，可关闭摄像头继续"
        )

        XCTAssertEqual(unavailable.cameraTitle, "摄像头不可用")
        XCTAssertEqual(unavailable.cameraSystemImage, "video.slash.fill")
        XCTAssertFalse(unavailable.cameraControlEnabled)
        XCTAssertEqual(unavailable.startTitle, "关闭摄像头继续")

        let available = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: false,
            isPreparing: false,
            isStartingCall: false,
            unavailableReason: nil
        )

        XCTAssertEqual(available.cameraTitle, "开启摄像头")
        XCTAssertEqual(available.cameraSystemImage, "video.slash.fill")
        XCTAssertTrue(available.cameraControlEnabled)
        XCTAssertEqual(available.startTitle, "开始呼叫")

        let preparing = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: true,
            isPreparing: true,
            isStartingCall: false,
            unavailableReason: nil
        )
        XCTAssertFalse(preparing.cameraControlEnabled)
    }

    private func startAudioHeartbeat(transport: RTCMediaHeartbeatHTTPTransport, callID: String = "audio-heartbeat") -> AppState {
        let state = makeRTCMediaHeartbeatState(transport: transport)
        var call = makeRTCMediaHeartbeatVideoCall(callID: callID)
        call.requestedMediaMode = "audio"
        call.mediaMode = "audio"
        state.activeVoiceCall = call
        state.startRTCMediaStateHeartbeatForTesting(
            callID: callID, roomID: "room-heartbeat", rtcToken: "rtc-token-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-heartbeat")
        )
        return state
    }

    private func heartbeatStates(_ transport: RTCMediaHeartbeatHTTPTransport) -> [String] {
        transport.requests().compactMap { request in
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return body["media_state"] as? String
        }
    }

    private func qualifyAudio(_ state: AppState) {
        state.handleVoiceMediaEvent(.iceConnected, callID: "audio-heartbeat")
        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "audio-heartbeat")
        state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: "audio-heartbeat")
    }

    func testAudioHeartbeatUsesTransportReadinessAfterDisconnect() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: (2...12).map {
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: Int64($0)))
        })
        let state = startAudioHeartbeat(transport: transport)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.handleVoiceMediaEvent(.callAccepted)
        state.handleVoiceMediaEvent(.iceConnected)
        for _ in 0..<100 where state.rtcMediaHeartbeatSnapshotForTesting?.hasReportedConnected != true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
        XCTAssertTrue(heartbeatStates(transport).contains("connected"))
        state.handleVoiceMediaEvent(.remoteAudioRTPReady)
        state.handleVoiceMediaEvent(.iceDisconnected)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "reconnecting")
        state.handleVoiceMediaEvent(.connectionRecovered)
        for _ in 0..<100 where heartbeatStates(transport).last != "connected" {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(heartbeatStates(transport).last, "connected")
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
    }

    func testAudioHeartbeatShortConnectedCallFlushesBeforeSingleHangup() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 150_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 3), delayNanoseconds: 30_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        state.endActiveVoiceCall()
        state.endActiveVoiceCall()
        XCTAssertTrue(state.isEndingActiveCall)
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true })
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(heartbeatStates(transport), ["connecting", "connected"])
        XCTAssertEqual(transport.requests().map { $0.url!.lastPathComponent }, ["media-state", "media-state", "hangup"])
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
    }

    func testAudioHeartbeatHangupTimeoutRemainsBoundedAndVisible() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 30_000_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        let started = Date()
        state.endActiveVoiceCall()
        for _ in 0..<160 where state.activeVoiceCall != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.2)
        XCTAssertEqual(state.toast, "通话已结束，连接记录同步未确认")
        XCTAssertEqual(transport.requests().filter { $0.url?.path.hasSuffix("/hangup") == true }.count, 1)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
    }

    func testAudioHeartbeatPendingConnectionSurvivesImmediateReconnect() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: (2...4).map {
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: Int64($0)), delayNanoseconds: 50_000_000)
        })
        let state = startAudioHeartbeat(transport: transport)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        state.handleVoiceMediaEvent(.iceDisconnected)
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        XCTAssertEqual(heartbeatStates(transport), ["connecting", "connected", "reconnecting"])
    }

    func testAudioHeartbeatUnconnectedCancelIgnoresLateReadyEvents() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 100_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        state.activeVoiceCall?.mediaState = .preparing
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.endActiveVoiceCall()
        qualifyAudio(state)
        XCTAssertNil(state.activeVoiceCall?.connectedAt)
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(heartbeatStates(transport), ["connecting"])
        XCTAssertEqual(transport.requests().filter { $0.url?.path.hasSuffix("/cancel") == true }.count, 1)
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true })
    }

    func testAudioHeartbeatContextReplacementRejectsLateResultAndHangup() async throws {
        for replacement in ["account", "device", "epoch"] {
            let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
                .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 999), delayNanoseconds: 100_000_000, ignoresCancellation: true)
            ])
            let state = startAudioHeartbeat(transport: transport)
            await waitForRTCMediaHeartbeatRequests(1, transport: transport)
            qualifyAudio(state)
            state.endActiveVoiceCall()
            state.updateRTCMediaHeartbeatContextForTesting { context in
                switch replacement {
                case "account": context.accountID = "different-account"
                case "device": context.deviceID = "different-device"
                default: context.sessionEpoch = "different-epoch"
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting, replacement)
            XCTAssertNotEqual(state.activeVoiceCall?.stateVersion, 999, replacement)
            XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true }, replacement)
        }
    }

    func testVideoMediaHeartbeatReportsConnectingConnectedAndReconnectingSerially() async throws {
        XCTAssertEqual(
            RTCMediaStateHeartbeatFailurePolicy.defaultIntervalNanoseconds,
            10_000_000_000
        )
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 2), delayNanoseconds: 80_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 3), delayNanoseconds: 20_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 4), delayNanoseconds: 20_000_000)
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-heartbeat")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-heartbeat",
            roomID: "room-heartbeat",
            rtcToken: "rtc-token-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-heartbeat")
        )

        state.renewRTCMediaStateHeartbeatForTesting()
        state.renewRTCMediaStateHeartbeatForTesting()
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.handleVideoMediaEvent(.mediaConnected, callID: "video-heartbeat")
        state.handleVideoMediaEvent(.remoteAudioTrackReady, callID: "video-heartbeat")
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        state.handleVideoMediaEvent(.reconnecting, callID: "video-heartbeat")
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 4 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let states = transport.requests().compactMap { request -> String? in
            guard request.url?.path.hasSuffix("/media-state") == true,
                  let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return nil
            }
            return object["media_state"] as? String
        }
        XCTAssertEqual(states, ["connecting", "connected", "reconnecting"])
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 4)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatRecoversLeaseOnceAndForegroundRenewsImmediately() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_participant_lease_expired")),
            .init(
                result: HTTPTransportResult(
                    data: Data(
                        """
                        {"ok":true,"data":{
                          "room_id":"room-lease",
                          "rtc_token":"rtc-token-renewed",
                          "self_participant":{
                            "uid":"uid-1",
                            "device_id":"ios-device-renewed",
                            "device_type":"ios",
                            "role":"self"
                          },
                          "participants":[]
                        }}
                        """.utf8
                    ),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-lease", stateVersion: 7)),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-lease", stateVersion: 8))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-lease")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-lease",
            roomID: "room-lease",
            rtcToken: "rtc-token-original",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-original")
        )
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)

        let firstPaths = transport.requests().prefix(3).compactMap(\.url?.path)
        XCTAssertEqual(firstPaths, [
            "/api/rtc/calls/video-lease/media-state",
            "/api/rtc/rooms/room-lease/join",
            "/api/rtc/calls/video-lease/media-state"
        ])
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.rtcToken, "rtc-token-renewed")
        XCTAssertEqual(
            state.rtcMediaHeartbeatSnapshotForTesting?.selfParticipant?.deviceID,
            "ios-device-renewed"
        )
        XCTAssertEqual(state.activeVoiceCall?.rtcToken, "rtc-token-renewed")

        state.resumeRTCMediaStateHeartbeatAfterForegroundForTesting()
        await waitForRTCMediaHeartbeatRequests(4, transport: transport)
        XCTAssertEqual(
            transport.requests()[3].url?.path,
            "/api/rtc/calls/video-lease/media-state"
        )
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 8)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatRetriesStateVersionConflictWithoutParticipantRejoin() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_state_version_conflict")),
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_state_version_conflict")),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-conflict", stateVersion: 14))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-conflict")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-conflict",
            roomID: "room-conflict",
            rtcToken: "rtc-token-conflict",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-conflict")
        )
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 14 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            transport.requests().compactMap(\.url?.path),
            Array(repeating: "/api/rtc/calls/video-conflict/media-state", count: 3)
        )
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 14)
        XCTAssertTrue(state.rtcMediaHeartbeatTimerArmedForTesting)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatAuthoritativeTerminalAfterNinetySecondsEndsAndCleansUp() async throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-terminal-heartbeat", stateVersion: 5)),
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_call_not_active"))
        ])
        let state = makeRTCMediaHeartbeatState(
            transport: transport,
            now: { now }
        )
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-terminal-heartbeat")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-terminal-heartbeat",
            roomID: "room-terminal-heartbeat",
            rtcToken: "rtc-token-terminal-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-terminal-heartbeat")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 5 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 5)
        now = now.addingTimeInterval(91)
        state.renewRTCMediaStateHeartbeatForTesting()
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        await waitForCallEnd { state.activeVoiceCall == nil }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(state.calls.first?.endReason, "server_heartbeat_terminal")
        XCTAssertEqual(state.toast, "视频通话已结束")
    }

    func testVideoMediaHeartbeatLateCallResponseCannotMutateReplacementAndTerminationCancels() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(
                result: rtcMediaHeartbeatCallResult(callID: "video-a", stateVersion: 101),
                delayNanoseconds: 120_000_000,
                ignoresCancellation: true
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-b", stateVersion: 202))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-a")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-a",
            roomID: "room-a",
            rtcToken: "rtc-token-a",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-a")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)

        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-b")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-b",
            roomID: "room-b",
            rtcToken: "rtc-token-b",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-b")
        )
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(state.activeVoiceCall?.callID, "video-b")
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 202)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, "video-b")

        state.activeVoiceCall = nil
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        let requestCount = transport.requests().count
        state.renewRTCMediaStateHeartbeatForTesting()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.requests().count, requestCount)
    }

    func testVideoMediaHeartbeatInFlightSameCallRefreshQueuesFreshRenewalAndKeepsTimerArmed() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(
                result: rtcMediaHeartbeatCallResult(callID: "video-refresh", stateVersion: 11),
                delayNanoseconds: 100_000_000,
                ignoresCancellation: true
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-refresh", stateVersion: 12))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-refresh")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-refresh",
            roomID: "room-refresh",
            rtcToken: "rtc-token-old",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-old")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        let generation = try XCTUnwrap(state.rtcMediaHeartbeatSnapshotForTesting?.generation)

        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-refresh",
            roomID: "room-refresh",
            rtcToken: "rtc-token-fresh",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-fresh")
        )
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 12 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.generation, generation)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.rtcToken, "rtc-token-fresh")
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 12)
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertTrue(state.rtcMediaHeartbeatTimerArmedForTesting)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testMinimizedVideoCallDismissalKeepsActiveSessionAndCanRestore() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-1",
            callID: "video-1",
            roomID: "room-video-1",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        XCTAssertEqual(state.presentedCallSession?.callID, "video-1")

        state.setActiveVideoCallMinimized(true)
        XCTAssertNil(state.presentedCallSession)

        state.presentedCallSession = nil
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-1")
        XCTAssertTrue(state.activeVoiceCall?.isMinimized ?? false)

        state.setActiveVideoCallMinimized(false)
        XCTAssertEqual(state.presentedCallSession?.callID, "video-1")

        state.endActiveVoiceCall()
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "视频通话已结束")
        XCTAssertEqual(state.calls.first?.subtitle, "视频呼出 · 通话已结束")
        XCTAssertEqual(state.videoCallTerminalResult?.title, "通话已结束")
        XCTAssertEqual(state.videoCallTerminalResult?.cause, "你结束了本次通话，媒体已安全关闭。")
        XCTAssertEqual(state.videoCallTerminalResult?.nextAction, "返回聊天")
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/calls/video-1/hangup")
    }

    func testRTCMessageAndListProjectValidatedEndTimeWithoutChangingOuterAuthority() throws {
        for outer in [nil, "bad-time", "2026-08-24T00:01:45Z"] as [String?] {
            let state = makeHistoricalRTCTestState()
            let object = historicalRTCMessageObject(outer: outer)
            let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: object))
            let mapped = state.debugChatMessageForTesting(remote)
            let endedOuter = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(
                withJSONObject: historicalRTCMessageObject(outer: "2026-08-24T00:01:45Z")
            ))
            let expectedDisplay = state.debugChatMessageForTesting(endedOuter).time
            let record = try XCTUnwrap(mapped.rtcCallRecord)
            XCTAssertEqual(mapped.time, expectedDisplay)
            XCTAssertEqual(CachedMessage(message: mapped).model.time, mapped.time)
            XCTAssertEqual(mapped.createdAt, RTCCallRecordTimeProjection.parseServerTimestamp(outer))
            XCTAssertEqual(mapped.channelSeq, 81)
            XCTAssertEqual(remote.createdAt, outer)
            XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
            XCTAssertEqual(record.answeredAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:20Z"))
            XCTAssertEqual(record.mediaConnectedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:45Z"))
            XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
            XCTAssertEqual(record.presentation(viewerIsCaller: false).statusText, "通话时长 02:00")

            let listObject: [String: Any] = [
                "channel_id": "friend-1:uid-1", "channel_type": "direct",
                "last_msg_seq": 81, "unread_count": 0, "last_message": object
            ]
            let remoteConversation = try JSONDecoder().decode(RemoteConversation.self, from: JSONSerialization.data(withJSONObject: listObject))
            state.debugApplyRemoteConversationsForTesting([remoteConversation])
            let summary = try XCTUnwrap(state.conversations.first { $0.id == "friend-1:uid-1" })
            XCTAssertEqual(summary.time, expectedDisplay)
            XCTAssertEqual(summary.lastMsgSeq, 81)
            let summarizedMessage = try XCTUnwrap(summary.messages.first { $0.id == remote.messageID })
            XCTAssertEqual(summarizedMessage.createdAt, mapped.createdAt)
            XCTAssertEqual(summarizedMessage.channelSeq, 81)
        }
    }

    func testRTCMessageWithInvalidTypedTimesCannotInventHistoricalDisplay() throws {
        let state = makeHistoricalRTCTestState()
        var object = historicalRTCMessageObject(outer: "bad-time")
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["ended_at"] = "2026-08-23T23:58:00Z"
        object["payload"] = payload
        let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: object))
        let mapped = state.debugChatMessageForTesting(remote)
        XCTAssertNil(mapped.rtcCallRecord)
        XCTAssertNil(mapped.createdAt)
        XCTAssertEqual(mapped.channelSeq, 81)
        XCTAssertEqual(mapped.time, "时间未知")
    }

    func testDelayedRTCReconciliationUsesServerHistoryAndIgnoresTerminalReplays() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "delayed-terminal")
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "foreign-call", stateVersion: 99))
        XCTAssertEqual(state.activeVoiceCall?.callID, "delayed-terminal")
        XCTAssertTrue(state.calls.isEmpty)

        let terminal = historicalRTCRemoteCall(callID: "delayed-terminal")
        state.reconcileRTCCallsForTesting([terminal])
        XCTAssertNil(state.activeVoiceCall)
        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.callID, "delayed-terminal")
        XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp(terminal.startedAt))
        XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp(terminal.endedAt))
        XCTAssertNil(record.durationSeconds, "RemoteRTCCall has no media-connected time or duration contract")
        XCTAssertEqual(record.stateVersion, 8)
        XCTAssertNotEqual(record.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(record.time, "刚刚")
        let established = state.calls

        state.reconcileRTCCallsForTesting([terminal])
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
            callID: "delayed-terminal", started: "2026-08-20T00:00:00Z", ended: "2026-08-20T00:01:00Z", stateVersion: 7
        )])
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "delayed-terminal", stateVersion: 7))
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "foreign-call", stateVersion: 99))
        XCTAssertEqual(state.calls, established)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
    }

    func testDelayedRTCIncomingRawTerminalKeepsServerTimesAndUnknownDuration() throws {
        let state = makeHistoricalRTCTestState()
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-local", callID: "incoming-terminal",
            caller: makeUser(id: "friend-1", name: "Friend"), startedAt: "刚刚", source: "好友视频通话",
            requestedMediaMode: "video", stateVersion: 7
        )
        let terminal = historicalRTCTerminalEnvelope(callID: "incoming-terminal")
        state.debugHandleRealtimeEnvelopeForTesting(terminal)
        XCTAssertNil(state.incomingVoiceCall)
        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
        XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        XCTAssertNil(record.durationSeconds)
        XCTAssertEqual(record.stateVersion, 8)
        XCTAssertEqual(record.callType, "视频通话")
        let established = state.calls
        state.debugHandleRealtimeEnvelopeForTesting(terminal)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "incoming-terminal", stateVersion: 6))
        XCTAssertEqual(state.calls, established)
    }

    func testRTCTerminalMissingOrInvalidTimesRemainUnknownAcrossReconcileAndRawEvents() throws {
        let cases = [("", ""), ("bad-start", "bad-end"), ("2026-08-24T00:02:00Z", "2026-08-24T00:01:00Z")]
        for (started, ended) in cases {
            for rawEvent in [false, true] {
                let state = makeHistoricalRTCTestState()
                state.activeVoiceCall = historicalRTCActiveSession(callID: "unknown-history")
                if rawEvent {
                    state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(
                        callID: "unknown-history", started: started, ended: ended
                    ))
                } else {
                    state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
                        callID: "unknown-history", started: started, ended: ended
                    )])
                }
                let record = try XCTUnwrap(state.calls.first)
                XCTAssertNil(state.activeVoiceCall)
                XCTAssertNil(record.startedAt, "rawEvent=\(rawEvent)")
                XCTAssertNil(record.endedAt, "rawEvent=\(rawEvent)")
                XCTAssertNil(record.durationSeconds)
                XCTAssertEqual(record.time, "时间未知")
            }
        }
    }

    func testRTCRawTerminalDurationUsesMediaConnectionNotSignalAnswerOrLocalClock() throws {
        for suppliedDuration in [nil, 117] as [Int?] {
            let state = makeHistoricalRTCTestState()
            state.activeVoiceCall = historicalRTCActiveSession(callID: "media-history")
            let source = historicalRTCTerminalEnvelope(callID: "media-history")
            var payload = source.payload
            var call = try XCTUnwrap(payload["call"]?.objectValue)
            call["media_connected_at"] = .string("2026-08-23T23:59:45Z")
            if let suppliedDuration { call["duration_seconds"] = .int(suppliedDuration) }
            payload["call"] = .object(call)
            state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(type: source.type, requestID: source.requestID, payload: payload))
            let record = try XCTUnwrap(state.calls.first)
            XCTAssertEqual(record.durationSeconds, suppliedDuration.map(TimeInterval.init) ?? 120)
            XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        }
    }

    func testRTCUnknownTerminalTimeCanRefineOnceWithoutAcceptingOlderOrConflictingHistory() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "refine-history")
        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "refine-history")
        let unknown = try XCTUnwrap(state.calls.first)
        XCTAssertNil(unknown.endedAt)
        XCTAssertNil(unknown.durationSeconds)
        XCTAssertEqual(unknown.time, "时间未知")

        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(callID: "refine-history", stateVersion: 6)])
        XCTAssertEqual(state.calls.first, unknown)
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(callID: "refine-history", stateVersion: 7)])
        let canonical = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(canonical.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
        XCTAssertEqual(canonical.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        XCTAssertEqual(canonical.endReason, "caller_hangup")
        XCTAssertNil(canonical.durationSeconds)
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
            callID: "refine-history", ended: "2026-08-25T00:01:45Z", stateVersion: 8
        )])
        XCTAssertEqual(state.calls.first, canonical)
    }

    func testRTCOlderTerminalCannotEndNewerActiveLifecycleOrPersistHistory() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "versioned-history")
        XCTAssertEqual(state.callStore.claimLifecycle(
            scopeID: "isolated-rtc-test", callID: "versioned-history", direction: .outgoing, stateVersion: 7
        )?.isApplied, true)
        XCTAssertEqual(state.callStore.advanceLifecycle(
            callID: "versioned-history", to: .connected, stateVersion: 7
        )?.isApplied, true)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "versioned-history", stateVersion: 6))
        XCTAssertEqual(state.activeVoiceCall?.callID, "versioned-history")
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.revision, 7)
        XCTAssertTrue(state.calls.isEmpty)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "versioned-history", stateVersion: 8))
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.calls.first?.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
    }

    private func makeHistoricalRTCTestState() -> AppState {
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            apiContextOverride: makeIsolatedAPIContext()
        )
        state.currentUser = makeUser(id: "uid-1", name: "Me")
        state.calls = []
        return state
    }

    private func historicalRTCActiveSession(callID: String) -> VoiceCallSession {
        VoiceCallSession(
            id: "local-\(callID)", callID: callID, peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出", startedAt: "刚刚", statusText: "通话中", mediaState: .connected,
            isMuted: false, speakerOn: true, startedAtDate: Date(timeIntervalSince1970: 100),
            connectedAt: Date(timeIntervalSince1970: 120), requestedMediaMode: "video", mediaMode: "video", stateVersion: 7
        )
    }

    private func historicalRTCRemoteCall(
        callID: String, started: String = "2026-08-23T23:59:00Z",
        ended: String = "2026-08-24T00:01:45Z", stateVersion: Int64 = 8
    ) -> RemoteRTCCall {
        RemoteRTCCall(
            id: callID, status: "ended", callerUID: "friend-1", calleeUID: "uid-1",
            callType: "video", requestedMediaMode: "video", mediaMode: "video",
            createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-02T12:00:00Z",
            startedAt: started, acceptedAt: "2026-08-23T23:59:20Z", endedAt: ended,
            endReason: "caller_hangup", stateVersion: stateVersion
        )
    }

    private func historicalRTCTerminalEnvelope(
        callID: String, started: String = "2026-08-23T23:59:00Z",
        ended: String = "2026-08-24T00:01:45Z", stateVersion: Int = 8
    ) -> RealtimeEnvelope {
        RealtimeEnvelope(type: "rtc.call.ended", requestID: "history-\(callID)-\(stateVersion)", payload: [
            "event": .string("rtc.call.ended"),
            "call": .object([
                "id": .string(callID), "status": .string("ended"), "caller_uid": .string("friend-1"),
                "callee_uid": .string("uid-1"), "call_type": .string("video"), "requested_media_mode": .string("video"),
                "media_mode": .string("video"), "state_version": .int(stateVersion), "end_reason": .string("caller_hangup"),
                "started_at": .string(started), "accepted_at": .string("2026-08-23T23:59:20Z"), "ended_at": .string(ended),
                "created_at": .string("2026-09-01T12:00:00Z"), "updated_at": .string("2026-09-02T12:00:00Z")
            ])
        ])
    }

    private func historicalRTCMessageObject(outer: String?) -> [String: Any] {
        var message: [String: Any] = [
            "message_id": "historical-rtc-message", "channel_id": "friend-1:uid-1", "channel_type": "direct",
            "channel_seq": 81, "from_uid": "friend-1", "content_type": "rtc_call_record", "status": "sent",
            "updated_at": "2026-09-02T12:00:00Z", "received_at": "2026-09-03T12:00:00Z",
            "payload": [
                "schema_version": 1, "call_id": "historical-rtc-call", "call_type": "video",
                "caller_uid": "friend-1", "callee_uid": "uid-1", "final_outcome": "completed",
                "started_at": "2026-08-23T23:59:00Z", "answered_at": "2026-08-23T23:59:20Z",
                "media_connected_at": "2026-08-23T23:59:45Z", "ended_at": "2026-08-24T00:01:45Z",
                "duration_seconds": 120, "end_actor_uid": "friend-1", "reason_code": "completed",
                "text": "视频通话已结束", "fallback_text": "通话记录"
            ] as [String: Any]
        ]
        if let outer { message["created_at"] = outer }
        return message
    }

    func testRemoteVideoTerminalStateStopsVideoMediaBeforeClearingCall() async {
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeIsolatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-1",
            callID: "video-1",
            roomID: "room-video-1",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-1",
                status: "ended",
                roomID: "room-video-1",
                callerUID: "me",
                calleeUID: "peer-video",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video"
            )
        ])

        for _ in 0..<10 where videoMediaClient.stopReasons.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(videoMediaClient.stopReasons, ["remote_ended"])
        XCTAssertEqual(state.toast, "视频通话已结束")
        XCTAssertEqual(state.calls.first?.subtitle, "视频呼出 · 通话已结束")
        XCTAssertEqual(state.videoCallTerminalResult?.title, "对方已挂断")
        XCTAssertEqual(state.videoCallTerminalResult?.cause, "对方结束了本次通话。")

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-1",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "remote_hangup",
                stateVersion: 2
            )
        ])
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(videoMediaClient.stopReasons, ["remote_ended"])
        XCTAssertNil(state.activeVoiceCall)
    }

    @MainActor
    func testVideoTerminalResultDoesNotReplaceExistingPresentation() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let firstPeer = makeUser(id: "first-video-peer", name: "First Peer")
        let secondPeer = makeUser(id: "second-video-peer", name: "Second Peer")
        state.videoCallTerminalResult = VideoCallTerminalResult(
            callID: "first-video-call",
            peer: firstPeer,
            reason: "local_hangup"
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "second-video-session",
            callID: "second-video-call",
            roomID: "room-second-video",
            rtcToken: "rtc-token",
            peer: secondPeer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "second-video-call")

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.videoCallTerminalResult?.callID, "first-video-call")
        XCTAssertEqual(state.videoCallTerminalResult?.peer.id, "first-video-peer")
    }

    @MainActor
    func testRemoteVideoDowngradeMediaStateAppliesAudioMode() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-downgraded",
            callID: "video-remote-downgraded",
            roomID: "room-video-downgraded",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "来电",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            connectedAt: Date(timeIntervalSince1970: 100),
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            remoteVideoTrackReady: true
        )

        state.handleVideoMediaEvent(.remoteDowngradedToAudio, callID: "video-remote-downgraded")

        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteVideoTrackReady, false)
    }

    @MainActor
    func testVideoUpgradeRequestWithoutExistingEndpointOnlyShowsUnsupportedNotice() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        state.activeVoiceCall = VoiceCallSession(
            id: "video-audio-local",
            callID: "video-audio-mode",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方连接",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "audio",
            localCameraEnabled: false,
            remoteCameraEnabled: false
        )

        state.requestActiveAudioCallVideoUpgrade()

        XCTAssertEqual(state.toast, "当前接口暂不支持切回视频，请重新发起视频通话")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "等待对方连接")
    }

    func testTerminalVideoSignalCreatesNeutralRecordAndLateCanonicalTerminalRefinesWithoutRestartingOrStoppingTwice() async {
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeIsolatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-terminal",
            callID: "video-terminal",
            roomID: "room-video-terminal",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            stateVersion: 7
        )

        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "video-terminal")

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.calls.first?.status, "已结束")
        XCTAssertEqual(state.calls.first?.endReason, "server_signal_terminal")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)
        XCTAssertTrue(videoMediaClient.stopReasons.isEmpty)

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-terminal",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "caller_hangup",
                stateVersion: 6
            )
        ])
        XCTAssertEqual(state.calls.first?.endReason, "server_signal_terminal")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-terminal",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "caller_hangup",
                stateVersion: 7
            ),
            RemoteRTCCall(
                id: "different-call",
                status: "ended",
                endReason: "peer_hangup",
                stateVersion: 99
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.calls.first?.endReason, "caller_hangup")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)
        XCTAssertTrue(videoMediaClient.stopReasons.isEmpty)
    }

    func testVideoTerminalReasonsShareCauseAndSafeNextActionLanguage() {
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "rejected").title, "对方已拒绝")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "callee_busy").title, "对方正在通话中")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "timeout").title, "无人接听")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "permission_denied").title, "未获得媒体权限")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "media_failed").title, "媒体设备不可用")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "client_scope_changed").title, "会话已变更")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "license_revoked").title, "视频通话不可用")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "answered_elsewhere").title, "已在其他设备接听")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "network_error").title, "通话连接失败")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "remote_hangup").nextAction, "返回聊天")
    }

    func testVideoTerminalResultKeepsStableIDForSameCallID() {
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        let first = VideoCallTerminalResult(callID: " video-terminal ", peer: peer, reason: "remote_hangup")
        let second = VideoCallTerminalResult(callID: "video-terminal", peer: peer, reason: "remote_hangup")
        let fallback = VideoCallTerminalResult(peer: peer, reason: "remote_hangup")

        XCTAssertEqual(first.callID, "video-terminal")
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, fallback.id)
    }

    @MainActor
    func testVoiceMediaClosedEventClearsActiveCall() throws {
        let state = AppState()
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "",
            peer: makeUser(id: "peer-1", name: "Peer"),
            direction: "来电",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: nil
        )

        state.handleVoiceMediaEvent(.closed, callID: "call-1")

        XCTAssertNil(state.activeVoiceCall)
    }

    @MainActor
    func testVoiceRecoveryExhaustionHangsUpAndClearsActiveCall() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-recovery",
            callID: "call-recovery",
            roomID: "room-recovery",
            rtcToken: "rtc-token-memory-only",
            mediaBaseURL: "",
            peer: makeUser(id: "peer-recovery", name: "Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "网络不稳定",
            mediaState: .unstable,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: Date(timeIntervalSince1970: 1_010)
        )

        state.handleVoiceMediaEvent(.recoveryExhausted, callID: "call-recovery")
        for _ in 0..<100 where transport.requests().isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "语音连接恢复失败，通话已结束")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.path, "/api/rtc/calls/call-recovery/hangup")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["reason"] as? String, "ice_recovery_failed")
        XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("rtc-token-memory-only") == true)
    }

    @MainActor
    func testEndingVoiceCallRecordUsesClockTimeInsteadOfStaticJustNow() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-1", name: "Peer")
        state.calls = []
        state.isAuthenticated = true
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "",
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: Date(timeIntervalSince1970: 1_030)
        )

        state.endActiveVoiceCall()
        let immediateRecord = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(immediateRecord.callID, "call-1")
        XCTAssertEqual(immediateRecord.status, "已结束")
        await waitForCallEnd { state.activeVoiceCall == nil }

        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.callID, "call-1")
        XCTAssertEqual(record.status, "已结束")
        XCTAssertNotEqual(record.time, "刚刚")
        XCTAssertNotNil(record.startedAt)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/calls/call-1/hangup")
    }

    @MainActor
    func testCancelledUserDisplayAndVoiceCallAreBlocked() throws {
        let state = AppState()
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let cancelledByStatus = makeUser(id: "cancelled-1", name: "Old Name", status: "cancelled")
        let cancelledByAvatar = makeUser(id: "cancelled-2", name: "Old Avatar", avatarURL: cancelledUserAvatarPath)

        XCTAssertTrue(cancelledByStatus.isCancelledUser)
        XCTAssertEqual(cancelledByStatus.displayName, cancelledUserDisplayName)
        XCTAssertEqual(cancelledByStatus.displayAvatarURL, cancelledUserAvatarPath)
        XCTAssertTrue(cancelledByAvatar.isCancelledUser)
        XCTAssertEqual(cancelledByAvatar.displayName, cancelledUserDisplayName)

        state.currentUser = makeUser(id: "me", name: "Me")
        state.contacts = [cancelledByStatus]

        XCTAssertFalse(state.canStartDirectConversation(with: cancelledByStatus))
        XCTAssertFalse(state.canStartVoiceCall(with: cancelledByStatus))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: cancelledByStatus), "该用户已注销，无法发起语音通话")

        state.startOutgoingVoiceCall(to: cancelledByStatus)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "该用户已注销，无法发起语音通话")
    }

    func testMainShellBootstrapTraceStateClaimsOnceAndResetsOnBegin() throws {
        let trace = MainShellBootstrapTraceState()

        trace.begin(at: 10)

        XCTAssertEqual(trace.claimAppearance(at: 10.25), 250)
        XCTAssertNil(trace.claimAppearance(at: 10.5))
        XCTAssertEqual(trace.claimInteractive(at: 10.75), 750)
        XCTAssertNil(trace.claimInteractive(at: 11))

        trace.begin(at: 20)

        XCTAssertEqual(trace.claimAppearance(at: 20.25), 250)
        XCTAssertEqual(trace.claimInteractive(at: 20.5), 500)
    }

    func testAuthFlowGenerationStateIssuesCurrentAndInvalidatesTokens() throws {
        let state = AuthFlowGenerationState()
        let initial = state.currentToken()

        XCTAssertTrue(state.isCurrent(initial))

        let first = state.issueToken()
        XCTAssertFalse(state.isCurrent(initial))
        XCTAssertTrue(state.isCurrent(first))

        let second = state.issueToken()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))

        state.invalidate()
        XCTAssertFalse(state.isCurrent(second))
        XCTAssertTrue(state.isCurrent(state.currentToken()))
    }

    func testDeviceRevocationHandlingStateClaimsUntilFinished() throws {
        let state = DeviceRevocationHandlingState()

        XCTAssertFalse(state.isHandlingRevocation)
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.isHandlingRevocation)
        XCTAssertFalse(state.begin())

        state.finish()

        XCTAssertFalse(state.isHandlingRevocation)
        XCTAssertTrue(state.begin())

        state.finish()
        XCTAssertFalse(state.isHandlingRevocation)
    }

    func testAppStateRealtimeDeviceKickedClearsCurrentDeviceSession() throws {
        IMAppPolicyLastGoodStore.clearAll()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true)
        let context = makeAuthenticatedAPIContext()
        context.save()
        defer {
            IMAPIContext.clearStoredSession(resetDeviceIdentity: true)
            IMAppPolicyLastGoodStore.clearAll()
        }

        let realtime = DeviceKickRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: context
        )

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "error",
                requestID: "kick-1",
                payload: [
                    "code": .string("device_kicked"),
                    "reason_code": .string("device_kicked"),
                    "message": .string(DeviceRevocationDetector.logoutMessage)
                ]
            )
        )

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertEqual(state.toast, DeviceRevocationDetector.logoutMessage)
        XCTAssertFalse(IMAPIContext.load().hasIMSession)
        XCTAssertTrue(realtime.disconnectCalls.contains(false))
    }

    func testAppStateRealtimeResyncFullSchedulesExistingRecoveryRefresh() throws {
        let context = makeAuthenticatedAPIContext()
        let realtime = DeviceKickRealtimeTransport()
        let syncEngine = DefaultSyncEngine()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        defer { syncEngine.cancelRealtimeRecoveryTasks() }
        state.isAuthenticated = true

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "resync",
                requestID: "resync-full",
                payload: [
                    "full_sync": .bool(true)
                ]
            )
        )

        XCTAssertTrue(syncEngine.hasRealtimeRecoveryTask(.refresh))
    }

    func testAppStateRealtimeResyncChannelsSchedulesExistingConversationRecovery() throws {
        let context = makeAuthenticatedAPIContext()
        let realtime = DeviceKickRealtimeTransport()
        let syncEngine = DefaultSyncEngine()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        defer { syncEngine.cancelRealtimeRecoveryTasks() }
        state.isAuthenticated = true
        state.conversationStore.hydrateCachedConversations([
            Conversation(
                id: "group-1",
                title: "测试群",
                subtitle: "",
                kind: .group,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 3,
                accentHex: 0x6677FF,
                participants: [],
                messages: []
            )
        ])

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "resync",
                requestID: "resync-channel",
                payload: [
                    "channels": .array([
                        .object([
                            "channel_id": .string("group-1"),
                            "channel_type": .string("group")
                        ])
                    ])
                ]
            )
        )

        XCTAssertTrue(syncEngine.hasRealtimeRecoveryTask(.conversationFlush))
        XCTAssertEqual(syncEngine.drainRealtimeRecoveryConversations(), ["group-1"])
    }

    func testWorkspaceAccessClassifierDoesNotPromoteGroupMemberMissingToWorkspaceBlock() throws {
        let state = AppState()

        XCTAssertNil(state.workspaceAccessCode(from: "group_member_not_found current user is not a group member"))
        XCTAssertTrue(isGroupMemberNotFoundMessage("group_member_not_found current user is not a group member"))
        XCTAssertEqual(state.workspaceAccessCode(from: "tenant_member_not_found current enterprise membership is not found"), "tenant_member_not_found")
        XCTAssertEqual(state.workspaceAccessCode(from: "当前企业成员关系不存在，请切换其他企业"), "tenant_member_not_found")
        XCTAssertEqual(state.workspaceAccessCode(from: "workspace_switch_disabled by policy"), "workspace_switch_disabled")
        XCTAssertEqual(state.workspaceAccessCode(from: "管理员已关闭企业切换"), "workspace_switch_disabled")
        XCTAssertEqual(state.workspaceAccessCode(from: "member_projection_syncing"), "member_projection_syncing")
        XCTAssertEqual(state.workspaceAccessCode(from: "成员数据正在同步，请稍后重试"), "member_projection_syncing")
        XCTAssertEqual(state.workspaceAccessCode(from: "member_projection_failed"), "member_projection_failed")
        XCTAssertEqual(state.workspaceAccessCode(from: "成员数据同步失败，请联系管理员"), "member_projection_failed")
        XCTAssertEqual(state.workspaceAccessCode(from: "app_tenant_not_bound"), "workspace_not_found")
    }

    func testIOSAppIDNormalizesLegacyValuesAndPrioritizesCanonicalCandidate() throws {
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID(nil), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID(""), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("jht-ios-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("ios-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("web-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitongqiyetest.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitongim.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitong.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("custom-ios-app"), "custom-ios-app")
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("custom-ios-app", allowCustomAppID: false), IMAPIContext.canonicalIOSAppID)

        let candidates = IMAPIContext.iosAppIDCandidates(preferred: "web-main")
        XCTAssertEqual(candidates.first, IMAPIContext.canonicalIOSAppID)
        XCTAssertTrue(candidates.contains("web-main"))
        XCTAssertEqual(candidates.filter { $0 == IMAPIContext.canonicalIOSAppID }.count, 1)
        XCTAssertEqual(
            IMAPIContext.iosAppIDCandidates(preferred: "custom-ios-app", allowCustomAppID: false),
            [IMAPIContext.canonicalIOSAppID]
        )
    }

    func testReleaseGuardIgnoresLocalAppIDResidue() throws {
        XCTAssertEqual(
            IMAPIContext.normalizedIOSAppID("debug-local-app", allowCustomAppID: false),
            IMAPIContext.canonicalIOSAppID
        )
        XCTAssertEqual(
            IMAPIContext.iosAppIDCandidates(preferred: "debug-local-app", allowCustomAppID: false),
            [IMAPIContext.canonicalIOSAppID]
        )
    }

    func testLegacyIOSAppIDMigrationClearsOldSession() throws {
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "jht-ios-main",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "com.jianhuitongim.app",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "com.jianhuitong.app",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertFalse(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: IMAPIContext.canonicalIOSAppID,
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertFalse(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
    }

    func testAppStateSyncsConfirmedConversationAttachmentsIntoFileList() throws {
        let state = AppState()
        var conversation = makeConversation(id: "g_files", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.title = "产品内测群"
        var attachment = ChatMessage(
            id: "m1",
            senderId: "u_mia",
            senderName: "Mia",
            text: "risk-report.pdf",
            time: "10:00",
            channelSeq: 3,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "risk-report.pdf"
        attachment.attachmentFileID = "file-1"
        attachment.attachmentSizeBytes = 2_048
        attachment.attachmentMimeType = "application/pdf"
        attachment.attachmentMediaCategory = "pdf"
        attachment.attachmentExtension = "pdf"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentDownloadURL = "https://files.example.test/file-1/download"
        attachment.attachmentPreviewAvailable = true
        attachment.attachmentPreviewURL = "https://files.example.test/file-1/preview"

        var pending = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "draft.csv", time: "刚刚", kind: .file)
        pending.attachmentFileID = "file-pending"
        pending.attachmentName = "draft.csv"
        conversation.messages = [pending, attachment]

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.id == "file-1" }))
        XCTAssertEqual(file.name, "risk-report.pdf")
        XCTAssertEqual(file.type, "PDF")
        XCTAssertEqual(file.owner, "Mia")
        XCTAssertEqual(file.source, "产品内测群")
        XCTAssertEqual(file.scope, "群文件")
        XCTAssertEqual(file.channelID, "g_files")
        XCTAssertEqual(file.channelType, "group")
        XCTAssertTrue(file.downloadAvailable)
        XCTAssertTrue(file.previewAvailable)
        XCTAssertEqual(file.downloadURL, "https://files.example.test/file-1/download")
        XCTAssertEqual(file.previewURL, "https://files.example.test/file-1/preview")
        XCTAssertEqual(state.files(for: "g_files").map(\.id), ["file-1"])
        XCTAssertFalse(state.files.contains(where: { $0.id == "file-pending" }))
    }

    func testAppStateAttachmentEndpointOnlyMessageKeepsEndpointsOutOfFinalURLs() throws {
        let state = AppState()
        var conversation = makeConversation(id: "g_endpoint_only", kind: .group, unread: 0, lastMsgSeq: 9, lastReadSeq: 9)
        conversation.title = "交易通知群"
        var attachment = ChatMessage(
            id: "m-endpoint",
            senderId: "u_chen",
            senderName: "陈星",
            text: "README.md",
            time: "03:44",
            channelSeq: 9,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "README.md"
        attachment.attachmentFileID = "file-endpoint"
        attachment.attachmentSizeBytes = 633_000
        attachment.attachmentMimeType = "text/markdown"
        attachment.attachmentMediaCategory = "document"
        attachment.attachmentExtension = "md"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentPreviewAvailable = true
        attachment.attachmentDownloadURL = "/api/tenant/files/file-endpoint/presign-download"
        attachment.attachmentPreviewURL = "/api/tenant/files/file-endpoint"
        attachment.attachmentThumbnailURL = "/api/tenant/files/file-endpoint/thumbnail"
        conversation.messages = [attachment]

        XCTAssertNil(state.resolvedAttachmentDownloadURL(for: attachment))
        XCTAssertNil(state.resolvedAttachmentPreviewURL(for: attachment))
        XCTAssertNil(state.resolvedAttachmentThumbnailURL(for: attachment))
        XCTAssertTrue(state.attachmentCanRefreshRemoteFile(attachment))

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.id == "file-endpoint" }))
        XCTAssertEqual(file.downloadURL, "")
        XCTAssertEqual(file.previewURL, "")
        XCTAssertEqual(file.thumbnailURL, "")
        XCTAssertTrue(file.downloadAvailable)
        XCTAssertFalse(file.previewAvailable)
    }

    func testAppStateSyncsConversationAttachmentWithoutFileIDIntoFileList() throws {
        let state = AppState()
        var conversation = makeConversation(id: "risk-review", kind: .group, unread: 0, lastMsgSeq: 7, lastReadSeq: 7)
        conversation.title = "风控复核群"
        var attachment = ChatMessage(
            id: "message-readme",
            senderId: "u_chen",
            senderName: "陈星",
            text: "README.md",
            time: "03:44",
            channelSeq: 7,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "README.md"
        attachment.attachmentSizeBytes = 633_000
        attachment.attachmentMimeType = "text/markdown"
        attachment.attachmentMediaCategory = "document"
        attachment.attachmentExtension = "md"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentDownloadURL = "/api/tenant/files/message-readme/download"

        conversation.messages = [attachment]

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.name == "README.md" }))
        XCTAssertTrue(file.id.hasPrefix("local-attachment|risk-review|message-readme"))
        XCTAssertEqual(file.remoteFileID, "")
        XCTAssertEqual(file.remoteLookupID, "")
        XCTAssertEqual(file.source, "风控复核群")
        XCTAssertEqual(file.scope, "群文件")
        XCTAssertFalse(file.downloadAvailable)
        XCTAssertEqual(file.downloadURL, "")
        XCTAssertEqual(state.files(for: "risk-review").map(\.name), ["README.md"])
    }

    func testConversationStoreReplaceLocalMessageWithRemoteConfirmationStripsReadDetailsWhenDisabled() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        var local = makeMessage(id: "local_1", seq: 0, status: .read, isOutgoing: true, text: "hello")
        local.readBy = [makeReadReceipt(userID: "reader-1")]
        local.unreadBy = [makeReadReceipt(userID: "reader-2")]
        local.readCount = 1
        local.unreadCount = 2
        local.readStateKnown = true
        local.canViewReadDetails = true
        local.reactions = [Reaction(id: "local_1_ok", emoji: "ok", count: 1, reactedByMe: false)]
        local.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "reader-1"), time: "10:00")]
        conversation.messages = [local]
        store.conversations = [conversation]

        let replacement = try XCTUnwrap(store.replaceLocalMessageWithRemoteConfirmation(
            localID: "local_1",
            remoteMessageID: "remote-1",
            remoteMapped: makeMessage(id: "remote-1", seq: 1, isOutgoing: true),
            remoteDisplayTime: "10:01",
            remoteCreatedAt: nil,
            remoteChannelSeq: 1,
            in: "c1",
            readReceiptsEnabled: false
        ))

        let confirmed = replacement.confirmedMessage
        XCTAssertEqual(confirmed.status, .sent)
        XCTAssertTrue(confirmed.readBy.isEmpty)
        XCTAssertTrue(confirmed.unreadBy.isEmpty)
        XCTAssertNil(confirmed.readCount)
        XCTAssertNil(confirmed.unreadCount)
        XCTAssertFalse(confirmed.readStateKnown)
        XCTAssertFalse(confirmed.canViewReadDetails)
        XCTAssertEqual(confirmed.reactions, local.reactions)
        XCTAssertTrue(confirmed.reactionDetails.isEmpty)
    }

    func testConversationStoreUpdateLatestMessageSummaryIgnoresFailedAndDeletedMessages() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        var fileMessage = makeMessage(id: "file", seq: 2, text: "report.pdf", time: "10:00", kind: .file)
        fileMessage.attachmentName = "report.pdf"
        fileMessage.attachmentMediaCategory = "pdf"
        fileMessage.createdAt = Date(timeIntervalSince1970: 100)
        conversation.messages = [
            makeMessage(id: "failed", seq: 1, status: .failed, text: "failed"),
            fileMessage,
            makeMessage(id: "deleted", seq: 3, status: .sent, isDeletedLocally: true, text: "deleted")
        ]
        store.conversations = [conversation]

        store.updateConversationLatestFromMessages(at: 0)

        XCTAssertEqual(store.conversations[0].lastMessage, "[PDF] report.pdf")
        XCTAssertEqual(store.conversations[0].time, "10:00")
        XCTAssertEqual(store.conversations[0].sortTimestamp, 100)
    }

    func testConversationStoreApplyRecallUpdatesStatusAndCanUseRecallText() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1, text: "older", time: "09:59")
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m2", seq: 2, isOutgoing: true, text: "latest", time: "10:00")
        latest.createdAt = Date(timeIntervalSince1970: 200)
        latest.quote = "Alice: quoted original"
        latest.attachmentName = "secret.pdf"
        latest.attachmentFileID = "file-1"
        latest.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        latest.reactions = [Reaction(id: "m2_thumb", emoji: "👍", count: 1, reactedByMe: false)]
        conversation.messages = [older, latest]
        conversation.lastMessage = "latest"
        conversation.sortTimestamp = 200
        store.conversations = [conversation]

        XCTAssertTrue(store.applyRecall(messageID: "m2"))
        XCTAssertEqual(store.conversations[0].messages[1].status, .recalled)
        XCTAssertEqual(store.conversations[0].messages[1].text, "你撤回了一条消息")
        XCTAssertNil(store.conversations[0].messages[1].quote)
        XCTAssertNil(store.conversations[0].messages[1].attachmentName)
        XCTAssertNil(store.conversations[0].messages[1].attachmentFileID)
        XCTAssertNil(store.conversations[0].messages[1].attachmentUploadFailure)
        XCTAssertTrue(store.conversations[0].messages[1].reactions.isEmpty)
        XCTAssertEqual(store.conversations[0].lastMessage, "你撤回了一条消息")
        XCTAssertEqual(store.conversations[0].time, "10:00")

        XCTAssertTrue(store.applyRecall(messageID: "m1", conversationID: "c1", recallText: "你撤回了一条消息"))
        XCTAssertEqual(store.conversations[0].messages[0].status, .recalled)
        XCTAssertEqual(store.conversations[0].messages[0].text, "你撤回了一条消息")
        XCTAssertEqual(store.conversations[0].lastMessage, "你撤回了一条消息")
    }

    func testConversationStoreRealtimeRecallMatchesRemoteChannelAndHidesOriginalText() {
        let store = ConversationStore()
        var local = makeConversation(id: "local-group", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        local.messages = [makeMessage(id: "m1", seq: 1, text: "今天晚饭好吃", time: "18:18")]
        var system = makeConversation(id: "system_notification", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        system.messages = [makeMessage(id: "notice", seq: 1, status: .sent, text: "系统通知", kind: .system)]
        store.conversations = [system, local]

        XCTAssertFalse(store.applyRecall(
            messageID: "m1",
            conversationID: "other-group",
            channelIDForConversation: { conversation in
                conversation.id == "local-group" ? "remote-group" : conversation.id
            }
        ))
        XCTAssertEqual(store.conversations[1].messages[0].text, "今天晚饭好吃")

        XCTAssertTrue(store.applyRecall(
            messageID: "m1",
            conversationID: "remote-group",
            channelIDForConversation: { conversation in
                conversation.id == "local-group" ? "remote-group" : conversation.id
            }
        ))

        XCTAssertEqual(store.conversations[0].id, "system_notification")
        XCTAssertEqual(store.conversations[0].messages[0].text, "系统通知")
        XCTAssertEqual(store.conversations[1].messages[0].status, .recalled)
        XCTAssertEqual(store.conversations[1].messages[0].text, "User撤回了一条消息")
        XCTAssertEqual(store.conversations[1].lastMessage, "User撤回了一条消息")
    }

    func testConversationStoreApplyAdminDeletedMessageClearsTombstoneFieldsAndMatchesRemoteChannelID() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "local-c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1, text: "older", time: "09:59")
        older.createdAt = Date(timeIntervalSince1970: 100)
        var target = makeMessage(id: "m2", seq: 2, text: "report.pdf", time: "10:00", kind: .file)
        target.createdAt = Date(timeIntervalSince1970: 200)
        target.quote = "Alice: original"
        target.replyContext = MessageReplyContext(messageID: "source", summary: "source")
        target.attachmentName = "report.pdf"
        target.attachmentMeta = "application/pdf"
        target.attachmentFileID = "file-1"
        target.attachmentSizeBytes = 123
        target.attachmentPreviewURL = "https://example.test/preview"
        target.attachmentDownloadURL = "https://example.test/download"
        target.attachmentPreviewAvailable = true
        target.attachmentDownloadAvailable = true
        target.attachmentThumbnailURL = "https://example.test/thumb"
        target.attachmentUploadStatus = "uploaded"
        target.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        target.reactions = [Reaction(id: "m2_ok", emoji: "ok", count: 1, reactedByMe: true)]
        target.reactionDetails = [ReactionDetail(id: "d1", emoji: "ok", user: makeUser(id: "u2"), time: "10:01")]
        target.readBy = [makeReadReceipt(userID: "reader-1")]
        target.readCount = 1
        target.readStateKnown = true
        target.canViewReadDetails = true
        conversation.messages = [older, target]
        conversation.lastMessage = "report.pdf"
        conversation.sortTimestamp = 200
        store.conversations = [conversation]

        XCTAssertTrue(store.applyAdminDeletedMessage(
            messageID: "m2",
            conversationID: "remote-c1",
            channelIDForConversation: { _ in "remote-c1" }
        ))

        let deleted = store.conversations[0].messages[1]
        XCTAssertTrue(deleted.isDeletedLocally)
        XCTAssertEqual(deleted.status, .recalled)
        XCTAssertEqual(deleted.text, "原消息已删除")
        XCTAssertNil(deleted.quote)
        XCTAssertTrue(deleted.replyContext?.isUnavailable == true)
        XCTAssertNil(deleted.attachmentName)
        XCTAssertNil(deleted.attachmentMeta)
        XCTAssertNil(deleted.attachmentFileID)
        XCTAssertNil(deleted.attachmentSizeBytes)
        XCTAssertEqual(deleted.attachmentPreviewURL, "")
        XCTAssertEqual(deleted.attachmentDownloadURL, "")
        XCTAssertFalse(deleted.attachmentPreviewAvailable)
        XCTAssertFalse(deleted.attachmentDownloadAvailable)
        XCTAssertEqual(deleted.attachmentThumbnailURL, "")
        XCTAssertEqual(deleted.attachmentUploadStatus, "")
        XCTAssertNil(deleted.attachmentUploadFailure)
        XCTAssertTrue(deleted.reactions.isEmpty)
        XCTAssertTrue(deleted.reactionDetails.isEmpty)
        XCTAssertTrue(deleted.readBy.isEmpty)
        XCTAssertNil(deleted.readCount)
        XCTAssertFalse(deleted.readStateKnown)
        XCTAssertFalse(deleted.canViewReadDetails)
        XCTAssertEqual(store.conversations[0].lastMessage, "older")
    }

    func testConversationStoreRestoredDeletedOnlySnapshotIsNotUsableRemoteHistory() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true, text: "原消息已删除"),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true, text: "原消息已删除")
        ]

        let restored = CachedConversation(conversation: conversation, messageLimit: 40).model

        XCTAssertTrue(restored.messages.allSatisfy(\.isDeletedLocally))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: restored))
    }

    func testConversationStoreClearUnreadResetsTargetState() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "c1", unread: 4, lastMsgSeq: 12, lastReadSeq: 3),
            makeConversation(id: "c2", unread: 2, lastMsgSeq: 6, lastReadSeq: 1)
        ]

        store.clearUnread(conversationID: "c1", includeSystemConversations: false)

        XCTAssertEqual(store.conversations[0].unread, 0)
        XCTAssertEqual(
            store.conversations[0].lastReadSeq,
            3,
            "a local clear must not acknowledge message sequences that were never loaded contiguously"
        )
        XCTAssertFalse(store.conversations[0].hasUnreadReaction)
        XCTAssertEqual(store.conversations[0].unreadReactionCount, 0)
        XCTAssertEqual(store.conversations[0].firstUnreadSeq, 0)
        XCTAssertEqual(store.conversations[0].firstUnreadMessageID, "")
        XCTAssertEqual(store.conversations[0].unreadAnchorSeq, 0)
        XCTAssertEqual(store.conversations[0].unreadAnchorState, "none")
        XCTAssertEqual(store.conversations[1].unread, 2)
        XCTAssertEqual(store.conversations[1].lastReadSeq, 1)
    }

    func testConversationStoreClearUnreadCanTargetSystemConversationAlias() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "system", kind: .system, unread: 5, lastMsgSeq: 8, lastReadSeq: 1),
            makeConversation(id: "c1", unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        ]

        store.clearUnread(conversationID: "system_notification", includeSystemConversations: true)

        XCTAssertEqual(store.conversations[0].unread, 0)
        XCTAssertEqual(store.conversations[0].lastReadSeq, 1)
        XCTAssertEqual(store.conversations[1].unread, 3)
    }

    func testConversationStoreClearUnreadResolvesSystemAliasWithMatcher() {
        let store = ConversationStore()
        var matchedIDs: [String] = []
        store.conversations = [
            makeConversation(id: "system", kind: .system, unread: 5, lastMsgSeq: 8, lastReadSeq: 1),
            makeConversation(id: "c1", unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        ]

        store.clearUnread(conversationID: " system_notification ") { channelID in
            matchedIDs.append(channelID)
            return channelID == "system_notification"
        }

        XCTAssertEqual(matchedIDs, ["system_notification"])
        XCTAssertEqual(store.conversations[0].unread, 0)
        XCTAssertEqual(store.conversations[0].lastReadSeq, 1)
        XCTAssertEqual(store.conversations[1].unread, 3)
    }

    func testConversationStoreReplaceSystemConversationPreservesPreferredPreviousSystemState() {
        let store = ConversationStore()
        let normal = makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 0)
        var legacySystem = makeConversation(id: "legacy_system", kind: .system, unread: 2, lastMsgSeq: 7, lastReadSeq: 1)
        legacySystem.isPinned = false
        legacySystem.isMuted = true
        var preferredSystem = makeConversation(id: "system_notification", kind: .system, unread: 4, lastMsgSeq: 9, lastReadSeq: 2)
        preferredSystem.isPinned = true
        preferredSystem.isMuted = true
        store.conversations = [normal, legacySystem, preferredSystem]
        var capturedPrevious: Conversation?

        store.replaceSystemConversation { previous in
            capturedPrevious = previous
            var next = makeConversation(id: "system_notification", kind: .system, unread: 1, lastMsgSeq: previous?.lastMsgSeq ?? 0, lastReadSeq: 0)
            next.isPinned = previous?.isPinned ?? false
            next.isMuted = previous?.isMuted ?? false
            return next
        }

        XCTAssertEqual(capturedPrevious?.id, "system_notification")
        XCTAssertEqual(store.conversations.map(\.id), ["system_notification", "c1"])
        XCTAssertTrue(store.conversations[0].isPinned)
        XCTAssertTrue(store.conversations[0].isMuted)
        XCTAssertEqual(store.conversations[0].lastMsgSeq, 9)
        XCTAssertEqual(store.conversations[1].id, "c1")
    }

    func testConversationStoreReplaceSystemConversationRemovesExistingSystemRowsWhenBuilderReturnsNil() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "system_notification", kind: .system, unread: 4, lastMsgSeq: 9, lastReadSeq: 2),
            makeConversation(id: "legacy_system", kind: .system, unread: 2, lastMsgSeq: 7, lastReadSeq: 1),
            makeConversation(id: "c1", kind: .group, unread: 1, lastMsgSeq: 3, lastReadSeq: 0)
        ]

        store.replaceSystemConversation { _ in nil }

        XCTAssertEqual(store.conversations.map(\.id), ["c1"])
    }

    func testAppStateMarkSystemConversationReadClearsUnreadWhenReadAckFails() async throws {
        let transport = SystemInboxReadHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        var system = makeConversation(id: "system_notification", kind: .system, unread: 2, lastMsgSeq: 2, lastReadSeq: 0)
        system.messages = [
            makeMessage(id: "inbox_system-1", seq: 1, status: .sent, kind: .system),
            makeMessage(id: "inbox_system-2", seq: 2, status: .sent, kind: .system)
        ]
        state.conversationStore.conversations = [system]
        state.inboxItems = [
            InboxItem(id: "system-1", title: "通知一", subtitle: "内容一", time: "10:00", category: "system", isRead: false, accentHex: 0),
            InboxItem(id: "system-2", title: "通知二", subtitle: "内容二", time: "10:01", category: "system", isRead: false, accentHex: 0)
        ]

        var completionResult: Bool?
        state.markConversationRead("system_notification", showToast: false) { success in
            completionResult = success
        }
        for _ in 0..<80 where completionResult == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(completionResult, true)
        let refreshed = try XCTUnwrap(state.conversations.first(where: { $0.id == "system_notification" }))
        XCTAssertEqual(refreshed.unread, 0)
        XCTAssertEqual(refreshed.lastReadSeq, refreshed.lastMsgSeq)
        XCTAssertTrue(state.inboxItems.allSatisfy { $0.isAnnouncement || $0.isRead })
        XCTAssertTrue(transport.requestPaths().contains("/api/tenant/inbox/system/read"))
        XCTAssertTrue(transport.requestPaths().contains("/api/im/read-ack"))
    }

    func testAppStateVisibleTextAndImageReadTargetsDrainAfterInFlightAckWithoutNewMessage() async throws {
        for kind in [MessageKind.text, .image] {
            let persistenceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("read-ack-coalescing-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: persistenceRoot) }
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
                cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
            )
            let gate = FirstReadAckSuspensionGate()
            let transport = ReadAckCoalescingHTTPTransport(firstRequestGate: gate)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                messagePersistence: persistence,
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.isAuthenticated = true
            var conversation = makeConversation(
                id: "read-convergence-group",
                kind: .group,
                unread: 1,
                lastMsgSeq: 1,
                lastReadSeq: 0
            )
            conversation.messages = [
                makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
            ]
            conversation.messageCoveredThroughSeq = 1
            state.conversationStore.conversations = [conversation]

            state.markConversationRead(conversation.id, showToast: false)
            for _ in 0..<80 {
                if await gate.isWaiting() { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let firstRequestIsWaiting = await gate.isWaiting()
            XCTAssertTrue(firstRequestIsWaiting, "first read ack did not reach the suspension gate for \(kind)")

            conversation.messages.append(
                makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: kind)
            )
            conversation.lastMsgSeq = 2
            conversation.unread = 2
            conversation.messageCoveredThroughSeq = 2
            state.conversationStore.conversations = [conversation]
            state.markConversationRead(conversation.id, showToast: false)

            await gate.resumeFirst()
            let syncKey = "group|read-convergence-group"
            for _ in 0..<120 {
                if transport.requestedSequences().count == 2,
                   !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            XCTAssertEqual(transport.requestedSequences(), [1, 2], "queued visible target was not drained for \(kind)")
            let refreshed = try XCTUnwrap(state.conversations.first(where: { $0.id == conversation.id }))
            XCTAssertEqual(refreshed.lastReadSeq, 2)
            XCTAssertEqual(refreshed.unread, 0)
        }
    }

    func testAppStateVisibleQueuedReadDoesNotConsumeUnseenArrival() async throws {
        for kind in [MessageKind.text, .image] {
            let persistenceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("read-ack-coalescing-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: persistenceRoot) }
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
                cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
            )
            let gate = FirstReadAckSuspensionGate()
            let transport = ReadAckCoalescingHTTPTransport(firstRequestGate: gate)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: NoopVoiceMediaClient(),
                messagePersistence: persistence,
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.isAuthenticated = true
            var conversation = makeConversation(
                id: "read-convergence-group",
                kind: .group,
                unread: 1,
                lastMsgSeq: 1,
                lastReadSeq: 0
            )
            conversation.messages = [
                makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
            ]
            conversation.messageCoveredThroughSeq = 1
            state.conversationStore.conversations = [conversation]

            state.markConversationRead(conversation.id, throughSeq: 1, showToast: false)
            for _ in 0..<80 {
                if await gate.isWaiting() { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let firstRequestIsWaiting = await gate.isWaiting()
            XCTAssertTrue(firstRequestIsWaiting, "first read ack did not reach the suspension gate for \(kind)")

            conversation.messages.append(
                makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: kind)
            )
            conversation.lastMsgSeq = 2
            conversation.unread = 2
            conversation.messageCoveredThroughSeq = 2
            state.conversationStore.conversations = [conversation]
            state.markConversationRead(conversation.id, throughSeq: 2, showToast: false)
            // A third message arrives while ACK1 is suspended, but has not been
            // observed by the viewport. Finishing the queue must retain target2.
            conversation.messages.append(makeMessage(id: "unseen-3", senderId: "peer-1", seq: 3, kind: .text))
            conversation.lastMsgSeq = 3
            conversation.messageCoveredThroughSeq = 3
            conversation.unread = 3
            state.conversationStore.conversations = [conversation]

            await gate.resumeFirst()
            let syncKey = "group|read-convergence-group"
            for _ in 0..<120 {
                if transport.requestedSequences().count == 2,
                   !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            XCTAssertEqual(transport.requestedSequences(), [1, 2], "queued visible target was not drained for \(kind)")
            let refreshed = try XCTUnwrap(state.conversations.first(where: { $0.id == conversation.id }))
            XCTAssertEqual(refreshed.lastReadSeq, 2)
            XCTAssertEqual(refreshed.unread, 1)
            XCTAssertEqual(refreshed.firstUnreadSeq, 3)
            // Repeating the observed target must not clear unread3 locally.
            state.markConversationRead(conversation.id, throughSeq: 2, showToast: false)
            XCTAssertEqual(state.conversations.first(where: { $0.id == conversation.id })?.unread, 1)
            XCTAssertEqual(transport.requestedSequences(), [1, 2])
        }
    }

    func testAppStateFailedQueuedReadAckPersistsAndRetriesTheSameTailToSuccess() async throws {
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-ack-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
            cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
        )
        let gate = FirstReadAckSuspensionGate()
        let transport = ReadAckCoalescingHTTPTransport(
            firstRequestGate: gate,
            failSecondRequest: true
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        var conversation = makeConversation(
            id: "read-convergence-group",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.messages = [
            makeMessage(id: "incoming-1", senderId: "peer-1", seq: 1, kind: .text)
        ]
        conversation.messageCoveredThroughSeq = 1
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        state.conversationStore.conversations = [conversation]

        state.markConversationRead(conversation.id, showToast: false)
        for _ in 0..<80 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let firstRequestIsWaiting = await gate.isWaiting()
        XCTAssertTrue(firstRequestIsWaiting)

        conversation.messages.append(
            makeMessage(id: "incoming-2", senderId: "peer-1", seq: 2, kind: .text)
        )
        conversation.lastMsgSeq = 2
        conversation.unread = 2
        conversation.messageCoveredThroughSeq = 2
        state.conversationStore.conversations = [conversation]
        state.markConversationRead(conversation.id, showToast: false)

        await gate.resumeFirst()
        let syncKey = "group|read-convergence-group"
        for _ in 0..<120 {
            if transport.requestedSequences().count == 2,
               !state.conversationStore.isReadAckSyncInFlight(syncKey: syncKey) {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(transport.requestedSequences(), [1, 2])
        let refreshed = try XCTUnwrap(state.conversations.first(where: { $0.id == conversation.id }))
        XCTAssertEqual(refreshed.lastReadSeq, 1)
        XCTAssertEqual(refreshed.unread, 1)
        XCTAssertEqual(refreshed.firstUnreadSeq, 2)
        XCTAssertEqual(
            state.conversationStore.locallyReadSeq(forKey: syncKey),
            1,
            "failed ack2 must not advance the local authoritative high-water"
        )

        try await Task.sleep(nanoseconds: 1_100_000_000)
        await state.recoverDurableReadAcksForTesting()

        XCTAssertEqual(transport.requestedSequences(), [1, 2, 2])
        let recovered = try XCTUnwrap(state.conversations.first(where: { $0.id == conversation.id }))
        XCTAssertEqual(recovered.lastReadSeq, 2)
        XCTAssertEqual(recovered.unread, 0)
        XCTAssertEqual(state.conversationStore.locallyReadSeq(forKey: syncKey), 2)
    }

    func testDurableReadAckRecoveryIsSingleFlightAndBackgroundStopsBeforeClaimingNextRow() async throws {
        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-ack-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: persistenceRoot.appendingPathComponent("Application Support", isDirectory: true),
            cachesBase: persistenceRoot.appendingPathComponent("Caches", isDirectory: true)
        )
        let gate = FirstReadAckSuspensionGate()
        let transport = LifecycleReadAckHTTPTransport(suspendedRequestNumber: 3, gate: gate)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let context = makeAuthenticatedAPIContext()
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            messagePersistence: persistence,
            apiContextOverride: context
        )
        state.isAuthenticated = true
        var first = makeConversation(
            id: "lifecycle-a",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        first.messages = [makeMessage(id: "lifecycle-a-1", senderId: "peer-1", seq: 1, kind: .text)]
        first.messageCoveredThroughSeq = 1
        var second = makeConversation(
            id: "lifecycle-b",
            kind: .group,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        second.messages = [makeMessage(id: "lifecycle-b-1", senderId: "peer-1", seq: 1, kind: .text)]
        second.messageCoveredThroughSeq = 1
        state.conversationStore.conversations = [first, second]

        var firstCompleted: Bool?
        state.markConversationRead(first.id, showToast: false) { firstCompleted = $0 }
        for _ in 0..<120 where firstCompleted == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(firstCompleted, false)

        var secondCompleted: Bool?
        state.markConversationRead(second.id, showToast: false) { secondCompleted = $0 }
        for _ in 0..<120 where secondCompleted == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(secondCompleted, false)
        XCTAssertEqual(transport.requestCount(), 2)

        state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: true)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let firstTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        for _ in 0..<120 {
            if await gate.isWaiting() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let recoveryRequestIsWaiting = await gate.isWaiting()
        XCTAssertTrue(recoveryRequestIsWaiting)
        let secondTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        let thirdTrigger = Task { await state.recoverDurableReadAcksForTesting(requiresActiveScene: true) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(transport.requestCount(), 3, "multiple recovery triggers must share one consumer")

        state.appDidEnterBackground()
        await gate.resumeFirst()
        await firstTrigger.value
        await secondTrigger.value
        await thirdTrigger.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.requestCount(), 3, "background transition must stop before the next row is sent")

        let ticket = try await persistence.ensureTicket(context: context, sessionGeneration: 1)
        let states = try await persistence.ackStates(ticket: ticket, type: "read")
        let attemptsByChannel = Dictionary(uniqueKeysWithValues: states.map { ($0.channelID, $0.attemptCount) })
        XCTAssertEqual(attemptsByChannel["lifecycle-a"], 2)
        XCTAssertEqual(
            attemptsByChannel["lifecycle-b"],
            1,
            "the unsent second row must not consume retry budget while backgrounded"
        )
    }

    func testConversationStoreRemoveDirectConversationsMatchesPeerIDFromResolverParticipantsAndChannelParts() {
        let store = ConversationStore()
        var participantMatch = makeConversation(id: "direct_participant", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        participantMatch.participants = [makeUser(id: "peer-1")]
        var retainedDirect = makeConversation(id: "direct_retained", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        retainedDirect.participants = [makeUser(id: "peer-2")]
        var retainedGroup = makeConversation(id: "group:peer-1", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        retainedGroup.participants = [makeUser(id: "peer-1")]
        store.conversations = [
            makeConversation(id: "direct_resolver", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0),
            participantMatch,
            makeConversation(id: "tenant:peer-1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0),
            retainedDirect,
            retainedGroup
        ]

        store.removeDirectConversations(peerID: " peer-1 ") { conversation in
            conversation.id == "direct_resolver" ? "peer-1" : nil
        }

        XCTAssertEqual(store.conversations.map(\.id), ["direct_retained", "group:peer-1"])
    }

    func testConversationStoreRemoveDirectConversationsIgnoresEmptyPeerID() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "tenant:peer-1", kind: .direct, unread: 1, lastMsgSeq: 2, lastReadSeq: 0)
        ]

        store.removeDirectConversations(peerID: "  ") { _ in "peer-1" }

        XCTAssertEqual(store.conversations.map(\.id), ["tenant:peer-1"])
    }

    func testConversationStoreMarkDirectConversationUnavailableSetsContextMessagesAndListState() {
        let store = ConversationStore()
        var direct = makeConversation(id: "direct-1", kind: .direct, unread: 3, lastMsgSeq: 4, lastReadSeq: 0)
        direct.subtitle = "可发送"
        let group = makeConversation(id: "group-1", kind: .group, unread: 2, lastMsgSeq: 4, lastReadSeq: 0)
        store.conversations = [direct, group]
        let context = DirectFriendRequestContext(
            targetUID: "peer-1",
            canApplyFriend: false,
            friendRequestStatus: "pending",
            reasonCode: "friendship_required"
        )

        store.markDirectConversationUnavailable(direct, context: context)

        XCTAssertEqual(store.directFriendRequestContext(conversationID: "direct-1")?.targetUID, "peer-1")
        XCTAssertEqual(store.directDisabledMessage(conversationID: "direct-1"), FriendAddPresentation.sentMessage)
        XCTAssertEqual(store.historyMessage(conversationID: "direct-1"), FriendAddPresentation.sentMessage)
        XCTAssertEqual(store.conversations[0].subtitle, "需要好友关系")
        XCTAssertEqual(store.conversations[0].unread, 0)
        XCTAssertEqual(store.conversations[1].id, "group-1")
        XCTAssertEqual(store.conversations[1].unread, 2)
    }

    func testConversationStoreMarkDirectConversationUnavailableIgnoresNonDirectConversation() {
        let store = ConversationStore()
        let group = makeConversation(id: "group-1", kind: .group, unread: 2, lastMsgSeq: 4, lastReadSeq: 0)
        store.conversations = [group]
        let context = DirectFriendRequestContext(
            targetUID: "peer-1",
            canApplyFriend: nil,
            friendRequestStatus: "",
            reasonCode: "friendship_required"
        )

        store.markDirectConversationUnavailable(group, context: context, fallbackMessage: "fallback")

        XCTAssertNil(store.directFriendRequestContext(conversationID: "group-1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "group-1"))
        XCTAssertNil(store.historyMessage(conversationID: "group-1"))
        XCTAssertEqual(store.conversations[0].unread, 2)
    }

    func testConversationStoreDeleteConversationRemovesTargetAndReturnsRemovedConversation() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2),
            makeConversation(id: "target", kind: .direct, unread: 3, lastMsgSeq: 5, lastReadSeq: 1),
            makeConversation(id: "newer", kind: .group, unread: 1, lastMsgSeq: 8, lastReadSeq: 7)
        ]

        let removed = store.deleteConversation(conversationID: " target ")

        XCTAssertEqual(removed?.id, "target")
        XCTAssertEqual(removed?.title, "target")
        XCTAssertEqual(removed?.unread, 3)
        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
    }

    func testConversationStoreDeleteConversationSkipsInvalidOrMissingTarget() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2),
            makeConversation(id: "newer", kind: .group, unread: 1, lastMsgSeq: 8, lastReadSeq: 7)
        ]

        XCTAssertNil(store.deleteConversation(conversationID: "   "))
        XCTAssertNil(store.deleteConversation(conversationID: "missing"))
        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
    }

    func testConversationStoreHydrateCachedConversationsReplacesListAndReturnsCount() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "old", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        ]

        let count = store.hydrateCachedConversations([
            makeConversation(id: "cached-1", kind: .direct, unread: 2, lastMsgSeq: 5, lastReadSeq: 4),
            makeConversation(id: "cached-2", kind: .group, unread: 0, lastMsgSeq: 9, lastReadSeq: 9)
        ])

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.conversations.map(\.id), ["cached-1", "cached-2"])
        XCTAssertEqual(store.conversations[0].unread, 2)
        XCTAssertEqual(store.conversations[1].kind, .group)
    }

    func testConversationStoreHydrateCachedConversationsDropsDuplicateConversationIDs() {
        let store = ConversationStore()
        var olderDuplicate = makeConversation(id: "cached", kind: .group, unread: 1, lastMsgSeq: 2, lastReadSeq: 1)
        olderDuplicate.sortTimestamp = 100
        var newerDuplicate = makeConversation(id: "cached", kind: .group, unread: 9, lastMsgSeq: 8, lastReadSeq: 7)
        newerDuplicate.sortTimestamp = 300

        let count = store.hydrateCachedConversations([
            olderDuplicate,
            newerDuplicate,
            makeConversation(id: "other", kind: .direct, unread: 0, lastMsgSeq: 4, lastReadSeq: 4)
        ])

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.conversations.map(\.id), ["cached", "other"])
        XCTAssertEqual(store.conversations[0].unread, 9)
        XCTAssertEqual(store.conversations[0].lastMsgSeq, 8)
    }

    func testConversationStoreHydrateCachedConversationsPreservesRuntimeReadState() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "old", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        ]
        store.rememberRead(key: "read-key", readSeq: 7)

        let count = store.hydrateCachedConversations([
            makeConversation(id: "cached", kind: .direct, unread: 0, lastMsgSeq: 8, lastReadSeq: 8)
        ])

        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.conversations.map(\.id), ["cached"])
        XCTAssertEqual(store.locallyReadSeq(forKey: "read-key"), 7)
    }

    func testConversationStoreInsertDirectConversationCreatesRowAtTopWithParticipantProfile() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        ]
        let participant = makeUser(
            id: "peer-1",
            name: "Alice",
            avatarURL: "https://avatar.example/alice.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "t2"
        )

        let created = store.insertDirectConversation(
            channelID: " self:peer-1 ",
            title: "Alice",
            participant: participant,
            accentHex: 88
        )

        XCTAssertEqual(created?.id, "self:peer-1")
        XCTAssertEqual(store.conversations.map(\.id), ["self:peer-1", "older"])
        XCTAssertEqual(store.conversations[0].kind, .direct)
        XCTAssertEqual(store.conversations[0].title, "Alice")
        XCTAssertEqual(store.conversations[0].subtitle, "单聊")
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["peer-1"])
        XCTAssertEqual(store.conversations[0].avatarURL, "https://avatar.example/alice.png")
        XCTAssertEqual(store.conversations[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversations[0].avatarUpdatedAt, "t2")
        XCTAssertEqual(store.conversations[0].accentHex, 88)
    }

    func testConversationStoreInsertDirectConversationSkipsEmptyAndReusesExistingChannelID() {
        let store = ConversationStore()
        var existing = makeConversation(id: "self:peer-1", kind: .direct, unread: 1, lastMsgSeq: 4, lastReadSeq: 3)
        existing.title = "Existing"
        store.conversations = [existing]

        XCTAssertNil(store.insertDirectConversation(
            channelID: "   ",
            title: "Invalid",
            participant: makeUser(id: "peer-2"),
            accentHex: 0
        ))

        let reused = store.insertDirectConversation(
            channelID: " self:peer-1 ",
            title: "Changed",
            participant: makeUser(id: "peer-1"),
            accentHex: 99
        )

        XCTAssertEqual(reused?.id, "self:peer-1")
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.conversations[0].title, "Existing")
        XCTAssertEqual(store.conversations[0].unread, 1)
        XCTAssertEqual(store.conversations[0].accentHex, existing.accentHex)
    }

    func testConversationStoreTogglePinnedSortsAndRestoresPreviousValue() {
        let store = ConversationStore()
        var older = makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "newer", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        newer.sortTimestamp = 200
        store.conversations = [newer, older]

        let change = store.toggleConversationPinned(conversationID: "older")

        XCTAssertEqual(change?.previousValue, false)
        XCTAssertEqual(change?.conversation.id, "older")
        XCTAssertEqual(change?.conversation.isPinned, true)
        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversations.first(where: { $0.id == "older" })?.isPinned, true)

        store.restoreConversationPinned(conversationID: "older", to: false)

        XCTAssertEqual(store.conversations.map(\.id), ["newer", "older"])
        XCTAssertEqual(store.conversations.first(where: { $0.id == "older" })?.isPinned, false)
    }

    func testConversationStoreToggleMutedRestoresWithoutSorting() {
        let store = ConversationStore()
        var older = makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 2)
        older.sortTimestamp = 100
        var newer = makeConversation(id: "newer", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        newer.sortTimestamp = 200
        store.conversations = [older, newer]

        let change = store.toggleConversationMuted(conversationID: "older")

        XCTAssertEqual(change?.previousValue, false)
        XCTAssertEqual(change?.conversation.id, "older")
        XCTAssertEqual(change?.conversation.isMuted, true)
        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversations.first(where: { $0.id == "older" })?.isMuted, true)

        store.restoreConversationMuted(conversationID: "older", to: false)

        XCTAssertEqual(store.conversations.map(\.id), ["older", "newer"])
        XCTAssertEqual(store.conversations.first(where: { $0.id == "older" })?.isMuted, false)
    }

    func testConversationStoreSetGroupConversationMutedMatchesIDAndName() {
        let store = ConversationStore()
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        var nameMatch = makeConversation(id: "legacy-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        store.conversations = [idMatch, nameMatch]

        XCTAssertTrue(store.setGroupConversationMuted(groupID: " group-1 ", groupName: "Ignored", isMuted: true))
        XCTAssertTrue(store.conversations[0].isMuted)
        XCTAssertFalse(store.conversations[1].isMuted)

        XCTAssertTrue(store.setGroupConversationMuted(groupID: "missing", groupName: " Team Blue ", isMuted: true))
        XCTAssertTrue(store.conversations[1].isMuted)
    }

    func testConversationStoreSetGroupConversationMutedIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ]

        XCTAssertFalse(store.setGroupConversationMuted(groupID: " ", groupName: " ", isMuted: true))
        XCTAssertFalse(store.conversations[0].isMuted)

        XCTAssertFalse(store.setGroupConversationMuted(groupID: "missing", groupName: "Missing", isMuted: true))
        XCTAssertFalse(store.conversations[0].isMuted)
    }

    func testConversationStoreUpdateGroupAllMutedConversationPreviewMatchesIDChannelAndName() {
        let store = ConversationStore()
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        var channelMatch = makeConversation(id: "legacy-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        channelMatch.title = "Channel Backed"
        var nameMatch = makeConversation(id: "name-backed", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        store.conversations = [idMatch, channelMatch, nameMatch]

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: " group-1 ", groupName: "Ignored", message: "id preview") { _ in "" })
        XCTAssertEqual(store.conversations[0].lastMessage, "id preview")
        XCTAssertEqual(store.conversations[0].time, "刚刚")

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: "group-2", groupName: "Ignored", message: "channel preview") { conversation in
            conversation.id == "legacy-channel" ? "group-2" : ""
        })
        XCTAssertEqual(store.conversations[1].lastMessage, "channel preview")

        XCTAssertTrue(store.updateGroupAllMutedConversationPreview(groupID: "missing", groupName: " Team Blue ", message: "name preview") { _ in "" })
        XCTAssertEqual(store.conversations[2].lastMessage, "name preview")
    }

    func testConversationStoreUpdateGroupAllMutedConversationPreviewIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ]

        XCTAssertFalse(store.updateGroupAllMutedConversationPreview(groupID: " ", groupName: " ", message: "ignored") { _ in "" })
        XCTAssertEqual(store.conversations[0].lastMessage, "")
        XCTAssertEqual(store.conversations[0].time, "")

        XCTAssertFalse(store.updateGroupAllMutedConversationPreview(groupID: "missing", groupName: "Missing", message: "ignored") { _ in "" })
        XCTAssertEqual(store.conversations[0].lastMessage, "")
        XCTAssertEqual(store.conversations[0].time, "")
    }

    func testConversationStoreRemoveParticipantFromGroupConversationMatchesIDAndNameAndUpdatesCount() {
        let store = ConversationStore()
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        idMatch.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        idMatch.memberCount = 2
        var nameMatch = makeConversation(id: "legacy", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        nameMatch.participants = [makeUser(id: "u3"), makeUser(id: "u4")]
        nameMatch.memberCount = 2
        store.conversations = [idMatch, nameMatch]

        XCTAssertTrue(store.removeParticipantFromGroupConversation(groupID: " group-1 ", groupName: "Ignored", userID: " u1 ", memberCount: 4))
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversations[0].memberCount, 4)
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u3", "u4"])

        XCTAssertTrue(store.removeParticipantFromGroupConversation(groupID: "missing", groupName: " Team Blue ", userID: "u3", memberCount: 3))
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u4"])
        XCTAssertEqual(store.conversations[1].memberCount, 3)
    }

    func testConversationStoreRemoveParticipantFromAllConversationsIgnoresEmptyAndCountsRemovals() {
        let store = ConversationStore()
        var first = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        var second = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.participants = [makeUser(id: "u1"), makeUser(id: "u3")]
        store.conversations = [first, second]

        XCTAssertEqual(store.removeParticipantFromAllConversations(userID: " "), 0)
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u1", "u3"])

        XCTAssertEqual(store.removeParticipantFromAllConversations(userID: " u1 "), 2)
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u3"])
    }

    func testConversationStoreUpdateConversationParticipantsTransformsAndCountsChangedParticipants() {
        let store = ConversationStore()
        var first = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        first.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        var second = makeConversation(id: "c2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        second.participants = [makeUser(id: "u3")]
        store.conversations = [first, second]

        let updatedCount = store.updateConversationParticipants { user in
            guard user.id == "u1" || user.id == "u3" else { return user }
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: user.username,
                name: user.name,
                title: user.title,
                department: user.department,
                phone: user.phone,
                phoneVerified: user.phoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.email,
                status: user.status,
                enterprise: user.enterprise,
                avatarSeed: user.avatarSeed,
                avatarURL: "https://avatar.example/\(user.id).png",
                avatarVersion: "v2",
                avatarUpdatedAt: "now",
                badges: user.badges
            )
        }

        XCTAssertEqual(updatedCount, 2)
        XCTAssertEqual(store.conversations[0].participants[0].avatarURL, "https://avatar.example/u1.png")
        XCTAssertEqual(store.conversations[0].participants[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversations[0].participants[1].avatarURL, "")
        XCTAssertEqual(store.conversations[1].participants[0].avatarURL, "https://avatar.example/u3.png")
    }

    func testConversationStoreUpdateConversationParticipantsSkipsEmptyAndUnchangedValues() {
        let store = ConversationStore()
        let empty = makeConversation(id: "empty", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var unchanged = makeConversation(id: "unchanged", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        unchanged.participants = [makeUser(id: "u1")]
        store.conversations = [empty, unchanged]

        XCTAssertEqual(store.updateConversationParticipants { $0 }, 0)
        XCTAssertTrue(store.conversations[0].participants.isEmpty)
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u1"])
    }

    func testConversationStoreRefreshDirectConversationProfilesUpdatesTitleParticipantsAndAvatar() {
        let store = ConversationStore()
        var directWithAvatar = makeConversation(id: "direct-1", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        directWithAvatar.title = "direct-1"
        var directWithoutAvatar = makeConversation(id: "direct-2", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        directWithoutAvatar.title = "Stable"
        var group = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        group.title = "Group"
        store.conversations = [directWithAvatar, directWithoutAvatar, group]

        let updatedCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { channelID in channelID == "direct-1" ? "Alice" : "" },
            participantsForChannel: { channelID in
                switch channelID {
                case "direct-1":
                    return [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
                case "direct-2":
                    return [makeUser(id: "u2", name: "Bob")]
                default:
                    return [makeUser(id: "ignored")]
                }
            }
        )

        XCTAssertEqual(updatedCount, 2)
        XCTAssertEqual(store.conversations[0].title, "Alice")
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversations[0].avatarURL, "https://avatar.example/u1.png")
        XCTAssertEqual(store.conversations[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversations[0].avatarUpdatedAt, "t2")
        XCTAssertEqual(store.conversations[1].title, "Stable")
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversations[1].avatarURL, "")
        XCTAssertEqual(store.conversations[2].title, "Group")
        XCTAssertTrue(store.conversations[2].participants.isEmpty)
    }

    func testConversationStoreRefreshDirectConversationProfilesSkipsEmptyAndUnchangedValues() {
        let store = ConversationStore()
        var direct = makeConversation(id: "direct-1", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        direct.title = "Alice"
        direct.participants = [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
        direct.avatarURL = "https://avatar.example/u1.png"
        direct.avatarVersion = "v2"
        direct.avatarUpdatedAt = "t2"
        store.conversations = [direct]

        let unchangedCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { _ in "Alice" },
            participantsForChannel: { _ in
                [makeUser(id: "u1", name: "Alice", avatarURL: "https://avatar.example/u1.png", avatarVersion: "v2", avatarUpdatedAt: "t2")]
            }
        )
        XCTAssertEqual(unchangedCount, 0)

        let emptyCount = store.refreshDirectConversationProfiles(
            channelIDForConversation: { $0.id },
            titleForChannel: { _ in "" },
            participantsForChannel: { _ in [] }
        )
        XCTAssertEqual(emptyCount, 0)
        XCTAssertEqual(store.conversations[0].title, "Alice")
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversations[0].avatarURL, "https://avatar.example/u1.png")
    }

    func testConversationStoreUpsertCreatedGroupConversationMergesExistingAndPreservesRuntimeState() {
        let store = ConversationStore()
        var existing = makeConversation(id: "legacy", kind: .group, unread: 5, lastMsgSeq: 9, lastReadSeq: 3)
        existing.title = "Old Name"
        existing.memberCount = 10
        existing.isPinned = true
        existing.isMuted = true
        existing.messages = [makeMessage(id: "m1", seq: 9)]
        existing.avatarURL = "https://avatar.example/group-old.png"
        existing.avatarVersion = "old-v"
        existing.hasMention = true
        existing.mentionCount = 2
        existing.mentionSummaryText = "@你"
        existing.sortTimestamp = 123
        store.conversations = [existing]

        let updated = store.upsertCreatedGroupConversation(
            groupID: " remote-1 ",
            name: "New Name",
            members: [makeUser(id: "u1"), makeUser(id: "u2")],
            invitedMemberCount: 5,
            accentHex: 42,
            sortTimestamp: 999,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(updated?.id, "legacy")
        XCTAssertEqual(store.conversations[0].title, "New Name")
        XCTAssertEqual(store.conversations[0].memberCount, 10)
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversations[0].unread, 5)
        XCTAssertEqual(store.conversations[0].isPinned, true)
        XCTAssertEqual(store.conversations[0].isMuted, true)
        XCTAssertEqual(store.conversations[0].avatarURL, "https://avatar.example/group-old.png")
        XCTAssertEqual(store.conversations[0].avatarVersion, "old-v")
        XCTAssertEqual(store.conversations[0].hasMention, true)
        XCTAssertEqual(store.conversations[0].mentionCount, 2)
        XCTAssertEqual(store.conversations[0].mentionSummaryText, "@你")
        XCTAssertEqual(store.conversations[0].sortTimestamp, 123)
    }

    func testConversationStoreUpsertCreatedGroupConversationCreatesNewRowAtTop() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "older", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ]

        let created = store.upsertCreatedGroupConversation(
            groupID: " group-1 ",
            name: "Team Blue",
            members: [makeUser(id: "u1")],
            invitedMemberCount: 3,
            accentHex: 77,
            sortTimestamp: 111,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(created?.id, "group-1")
        XCTAssertEqual(store.conversations.map(\.id), ["group-1", "older"])
        XCTAssertEqual(store.conversations[0].lastMessage, "群聊已创建")
        XCTAssertEqual(store.conversations[0].time, "刚刚")
        XCTAssertEqual(store.conversations[0].memberCount, 4)
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1"])
        XCTAssertEqual(store.conversations[0].accentHex, 77)
        XCTAssertEqual(store.conversations[0].sortTimestamp, 111)
        XCTAssertNil(store.upsertCreatedGroupConversation(
            groupID: "   ",
            name: "Invalid",
            members: [],
            invitedMemberCount: 0,
            accentHex: 0,
            channelIDForConversation: { $0.id }
        ))
        XCTAssertEqual(store.conversations.map(\.id), ["group-1", "older"])
    }

    func testConversationStoreEnsureGroupConversationMergesExistingOrAppendsMissingGroup() {
        let store = ConversationStore()
        var existing = makeConversation(id: "legacy", kind: .group, unread: 4, lastMsgSeq: 8, lastReadSeq: 2)
        existing.title = "Old Name"
        existing.isMuted = false
        existing.participants = [makeUser(id: "old")]
        existing.avatarURL = "https://avatar.example/group-old.png"
        existing.avatarUpdatedAt = "old-time"
        existing.messages = [makeMessage(id: "m1", seq: 8)]
        store.conversations = [existing]

        let updated = store.ensureGroupConversation(
            groupID: " remote-1 ",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: true,
            memberCount: 6,
            avatarURL: "",
            avatarVersion: "v2",
            avatarUpdatedAt: "",
            accentHex: 99,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(updated?.id, "legacy")
        XCTAssertEqual(store.conversations[0].title, "Team Blue")
        XCTAssertEqual(store.conversations[0].lastMessage, "公告")
        XCTAssertEqual(store.conversations[0].isMuted, false)
        XCTAssertEqual(store.conversations[0].memberCount, 6)
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversations[0].avatarURL, "https://avatar.example/group-old.png")
        XCTAssertEqual(store.conversations[0].avatarVersion, "v2")
        XCTAssertEqual(store.conversations[0].avatarUpdatedAt, "old-time")
        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])

        let cleared = store.ensureGroupConversation(
            groupID: "remote-1",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: true,
            memberCount: 6,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            avatarIsAuthoritative: true,
            accentHex: 99,
            channelIDForConversation: { conversation in conversation.id == "legacy" ? "remote-1" : conversation.id }
        )

        XCTAssertEqual(cleared?.avatarURL, "")
        XCTAssertEqual(cleared?.avatarVersion, "")
        XCTAssertEqual(cleared?.avatarUpdatedAt, "")
        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversations.map(\.id), ["legacy"])

        let appended = store.ensureGroupConversation(
            groupID: "new-group",
            name: "New Group",
            notice: "新公告",
            members: [makeUser(id: "u2")],
            muted: true,
            memberCount: 2,
            avatarURL: "https://avatar.example/new.png",
            avatarVersion: "v1",
            avatarUpdatedAt: "now",
            accentHex: 100,
            channelIDForConversation: { $0.id }
        )

        XCTAssertEqual(appended?.id, "new-group")
        XCTAssertEqual(store.conversations.map(\.id), ["legacy", "new-group"])
        XCTAssertEqual(store.conversations[1].lastMessage, "新公告")
        XCTAssertEqual(store.conversations[1].isMuted, true)
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["u2"])
        XCTAssertEqual(store.conversations[1].avatarURL, "https://avatar.example/new.png")
        XCTAssertEqual(store.conversations[1].avatarVersion, "v1")
        XCTAssertEqual(store.conversations[1].avatarUpdatedAt, "now")
        XCTAssertNil(store.ensureGroupConversation(
            groupID: "   ",
            name: "   ",
            notice: "",
            members: [],
            muted: false,
            memberCount: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            accentHex: 0,
            channelIDForConversation: { $0.id }
        ))
    }

    func testConversationStoreGroupMemberCountZeroPreservesKnownCount() {
        let store = ConversationStore()
        var existing = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        existing.title = "Team Blue"
        existing.memberCount = 91
        existing.participants = [makeUser(id: "u1"), makeUser(id: "u2")]
        store.conversations = [existing]

        XCTAssertNotNil(store.ensureGroupConversation(
            groupID: "group-1",
            name: "Team Blue",
            notice: "公告",
            members: [],
            muted: false,
            memberCount: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            accentHex: 42,
            channelIDForConversation: { $0.id }
        ))
        XCTAssertEqual(store.conversations[0].memberCount, 91)

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: "group-1",
            groupName: "Team Blue",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversations[0].memberCount, 91)
    }

    func testGroupInfoMemberCountDisplayDistinguishesUnknownFromZero() {
        let unknown = GroupInfo(
            id: "group-unknown",
            name: "交易通知群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        var known = unknown
        known.memberCount = 91

        XCTAssertNil(unknown.visibleMemberCount)
        XCTAssertEqual(unknown.memberCountDisplayText, "人数待同步")
        XCTAssertEqual(known.visibleMemberCount, 91)
        XCTAssertEqual(known.memberCountDisplayText, "91 人")
    }

    func testConversationStoreSetGroupConversationParticipantsMatchesIDAndNameAndUpdatesCount() {
        let store = ConversationStore()
        var idMatch = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        idMatch.title = "Original"
        idMatch.participants = [makeUser(id: "old-1")]
        idMatch.memberCount = 1
        var nameMatch = makeConversation(id: "legacy", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        nameMatch.title = "Team Blue"
        nameMatch.participants = [makeUser(id: "old-2")]
        nameMatch.memberCount = 1
        store.conversations = [idMatch, nameMatch]

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: " group-1 ",
            groupName: "Ignored",
            participants: [makeUser(id: "u1"), makeUser(id: "u2")],
            memberCount: 4
        ))
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["u1", "u2"])
        XCTAssertEqual(store.conversations[0].memberCount, 4)
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["old-2"])

        XCTAssertTrue(store.setGroupConversationParticipants(
            groupID: "missing",
            groupName: " Team Blue ",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversations[1].participants.map(\.id), ["old-2"])
        XCTAssertEqual(store.conversations[1].memberCount, 1)
    }

    func testConversationStoreSetGroupConversationParticipantsIgnoresEmptyOrMissingTarget() {
        let store = ConversationStore()
        var group = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        group.title = "Team"
        group.participants = [makeUser(id: "old")]
        group.memberCount = 1
        store.conversations = [group]

        XCTAssertFalse(store.setGroupConversationParticipants(
            groupID: " ",
            groupName: " ",
            participants: [makeUser(id: "u1")],
            memberCount: 3
        ))
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversations[0].memberCount, 1)

        XCTAssertFalse(store.setGroupConversationParticipants(
            groupID: "missing",
            groupName: "Missing",
            participants: [],
            memberCount: 0
        ))
        XCTAssertEqual(store.conversations[0].participants.map(\.id), ["old"])
        XCTAssertEqual(store.conversations[0].memberCount, 1)
    }

    func testConversationStoreAppendLocalOutgoingMessageUpdatesMessagesAndExplicitPreview() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.lastMessage = "previous"
        conversation.time = "09:00"
        conversation.sortTimestamp = 100
        store.conversations = [conversation]

        var message = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "hello", time: "刚刚")
        message.createdAt = Date(timeIntervalSince1970: 1_234)

        let updated = store.appendLocalOutgoingMessage(
            message,
            to: " c1 ",
            preview: "explicit preview"
        )

        XCTAssertEqual(updated?.id, "c1")
        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["local_1"])
        XCTAssertEqual(store.conversations[0].lastMessage, "explicit preview")
        XCTAssertEqual(store.conversations[0].time, "刚刚")
        XCTAssertEqual(store.conversations[0].sortTimestamp, 1_234)
    }

    func testConversationStoreAppendLocalOutgoingMessageUsesMessagePreviewAndSkipsMissingTarget() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        ]

        var fileMessage = makeMessage(id: "local_file", seq: 0, status: .sending, isOutgoing: true, text: "report.pdf", time: "刚刚", kind: .file)
        fileMessage.createdAt = Date(timeIntervalSince1970: 2_468)
        fileMessage.attachmentName = "report.pdf"
        fileMessage.attachmentMediaCategory = "pdf"

        XCTAssertNil(store.appendLocalOutgoingMessage(fileMessage, to: "missing"))
        XCTAssertTrue(store.conversations[0].messages.isEmpty)

        let updated = store.appendLocalOutgoingMessage(fileMessage, to: "c1")

        XCTAssertEqual(updated?.messages.map(\.id), ["local_file"])
        XCTAssertEqual(store.conversations[0].lastMessage, "[PDF] report.pdf")
        XCTAssertEqual(store.conversations[0].time, "刚刚")
        XCTAssertEqual(store.conversations[0].sortTimestamp, 2_468)
    }

    func testConversationStoreApplyLocalMessageEditUpdatesMessageAndPreview() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, text: "old text")
        message.isEdited = false
        conversation.messages = [message]
        conversation.lastMessage = "old text"
        conversation.time = "09:00"
        conversation.sortTimestamp = 100
        store.conversations = [conversation]

        XCTAssertTrue(store.applyLocalMessageEdit(
            messageID: " m1 ",
            conversationID: " c1 ",
            text: " updated text "
        ))

        XCTAssertEqual(store.conversations[0].messages[0].text, "updated text")
        XCTAssertTrue(store.conversations[0].messages[0].isEdited)
        XCTAssertEqual(store.conversations[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversations[0].lastMessage, "updated text")
        XCTAssertEqual(store.conversations[0].time, "09:00")
        XCTAssertEqual(store.conversations[0].sortTimestamp, 100)
    }

    func testConversationStoreApplyLocalMessageEditSkipsInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, text: "old text")]
        conversation.lastMessage = "old text"
        store.conversations = [conversation]

        XCTAssertFalse(store.applyLocalMessageEdit(messageID: " ", conversationID: "c1", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: " ", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: "c1", text: " "))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "missing", conversationID: "c1", text: "new"))
        XCTAssertFalse(store.applyLocalMessageEdit(messageID: "m1", conversationID: "missing", text: "new"))

        XCTAssertEqual(store.conversations[0].messages[0].text, "old text")
        XCTAssertFalse(store.conversations[0].messages[0].isEdited)
        XCTAssertEqual(store.conversations[0].lastMessage, "old text")
    }

    func testMessageEditSuccessReturnsToLatestOnlyForCurrentAuthoritativeProjection() throws {
        var current = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, text: "updated text")
        current.editRevision = 2

        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: false,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-b|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c2",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))

        current.editRevision = 1
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))
        current.editRevision = 2
        current.text = "different authoritative text"
        XCTAssertNil(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: "updated text",
            expectedRevision: 1,
            currentMessage: current
        ))

        current.text = "updated text"
        let success = try XCTUnwrap(messageEditAuthoritativeSuccess(
            saved: true,
            scope: "tenant-a|user-a",
            currentScope: "tenant-a|user-a",
            conversationID: "c1",
            currentConversationID: "c1",
            messageID: "m1",
            submittedText: " updated text ",
            expectedRevision: 1,
            currentMessage: current
        ))
        XCTAssertEqual(success.authoritativeRevision, 2)
        XCTAssertTrue(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-a|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
        XCTAssertFalse(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-b|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
        current.text = "newer competing edit"
        current.editRevision = 3
        XCTAssertFalse(messageEditAuthoritativeSuccessIsCurrent(
            success,
            currentScope: "tenant-a|user-a",
            currentConversationID: "c1",
            currentMessage: current
        ))
    }

    func testConversationStoreMarkAttachmentUploadFailedRetainsProvidedFailure() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = 0.4
        message.attachmentUploadStatus = "queued"
        conversation.messages = [message]
        store.conversations = [conversation]

        let failure = AttachmentUploadFailure(code: .http, httpStatus: 503, serverCode: "service_unavailable")
        XCTAssertTrue(store.markAttachmentUploadFailed(
            messageID: " m1 ", conversationID: " c1 ", failureStatus: " FAILED_PUT ", failure: failure
        ))

        XCTAssertEqual(store.conversations[0].messages[0].status, .failed)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentUploadStatus, "failed_put")
        XCTAssertEqual(store.conversations[0].messages[0].attachmentUploadFailure, failure)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentTransferProgress ?? -1, 0.4, accuracy: 0.001)
    }

    func testConversationStoreMarkAttachmentUploadRetryingUpdatesStatusProgressAndUploadStatus() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = nil
        message.attachmentUploadStatus = "failed"
        message.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertTrue(store.markAttachmentUploadRetrying(messageID: " m1 ", conversationID: " c1 "))

        XCTAssertNil(store.conversations[0].messages[0].attachmentUploadFailure)
        XCTAssertEqual(store.conversations[0].messages[0].status, .sending)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentTransferProgress ?? -1, 0.06, accuracy: 0.001)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentUploadStatus, "retrying")
    }

    func testConversationStoreUpdateAttachmentUploadStatusClearsPreviousFailure() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .file)
        message.attachmentUploadStatus = "failed_put"
        message.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        conversation.messages = [message]
        store.conversations = [conversation]

        let updated = try XCTUnwrap(store.updateAttachmentUploadStatus(
            " UPLOADED ", messageID: "m1", conversationID: "c1"
        ))

        XCTAssertEqual(updated.attachmentUploadStatus, "uploaded")
        XCTAssertNil(updated.attachmentUploadFailure)
        XCTAssertNil(store.conversations[0].messages[0].attachmentUploadFailure)
    }

    func testAttachmentUploadFailureMessageShowsOnlySafeDetailWhileFailed() throws {
        let state = AppState()
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .file)
        message.attachmentUploadStatus = "failed_put"
        message.attachmentUploadFailure = AttachmentUploadFailure(
            code: .http, httpStatus: 403, serverCode: "synthetic_token_without_punctuation"
        )

        let detail = try XCTUnwrap(state.attachmentUploadFailureMessage(for: message))
        XCTAssertEqual(detail, "文件内容上传失败，请重试\nHTTP · HTTP 403 · unrecognized_server_code")
        XCTAssertFalse(detail.contains("synthetic_token"))
        for status in [MessageDelivery.sending, .sent, .read, .recalled] {
            message.status = status
            XCTAssertNil(state.attachmentUploadFailureMessage(for: message))
        }
    }

    func testConversationStoreAttachmentUploadStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentTransferProgress = 0.7
        message.attachmentUploadStatus = "queued"
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadFailed(messageID: "m1", conversationID: "missing"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.markAttachmentUploadRetrying(messageID: "m1", conversationID: "missing"))

        XCTAssertEqual(store.conversations[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentTransferProgress ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentUploadStatus, "queued")
    }

    func testConversationStoreAttachmentFileIDAndProgressStateUpdatesMessage() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sending, isOutgoing: true, text: "report.pdf", kind: .file)
        message.attachmentFileID = "old-file"
        message.attachmentTransferProgress = nil
        conversation.messages = [message]
        store.conversations = [conversation]

        let fileUpdated = try XCTUnwrap(store.setAttachmentFileID(" file-2 ", messageID: " m1 ", conversationID: " c1 "))
        XCTAssertEqual(fileUpdated.attachmentFileID, "file-2")

        let progressUpdated = try XCTUnwrap(store.updateAttachmentProgress(0.42, messageID: " m1 ", conversationID: " c1 "))
        XCTAssertEqual(progressUpdated.attachmentTransferProgress ?? -1, 0.42, accuracy: 0.001)

        let cleared = try XCTUnwrap(store.updateAttachmentProgress(nil, messageID: " m1 ", conversationID: " c1 "))
        XCTAssertNil(cleared.attachmentTransferProgress)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentFileID, "file-2")
        XCTAssertNil(store.conversations[0].messages[0].attachmentTransferProgress)
    }

    func testConversationStoreUpdateMessageAttachmentCopiesMetadataAndUpdatesLatestPreview() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, text: "old.pdf", time: "09:00", kind: .file)
        message.attachmentName = "old.pdf"
        message.attachmentMediaCategory = "pdf"
        conversation.messages = [message]
        conversation.lastMessage = "[PDF] old.pdf"
        store.conversations = [conversation]

        var updated = message
        updated.attachmentName = "demo.mp4"
        updated.attachmentMeta = "video/mp4 · 4 MB"
        updated.attachmentFileID = "file-video"
        updated.attachmentSizeBytes = 4_194_304
        updated.attachmentPreviewURL = "https://example.test/preview"
        updated.attachmentDownloadURL = "https://example.test/download"
        updated.attachmentPreviewAvailable = true
        updated.attachmentDownloadAvailable = true
        updated.attachmentTransferProgress = 0.66
        updated.attachmentMimeType = "video/mp4"
        updated.attachmentCacheKey = "cache-video"
        updated.attachmentVersion = "v2"
        updated.attachmentChecksum = "checksum"
        updated.attachmentMediaCategory = "video"
        updated.attachmentExtension = "mp4"
        updated.attachmentThumbnailURL = "https://example.test/thumb"
        updated.attachmentPosterURL = "https://example.test/poster"
        updated.attachmentCoverURL = "https://example.test/cover"
        updated.attachmentPreviewKind = "video"
        updated.attachmentContentDisposition = "inline"
        updated.attachmentWidth = 1280
        updated.attachmentHeight = 720
        updated.attachmentDurationSeconds = 12.5
        updated.attachmentUploadStatus = "uploaded"

        let result = try XCTUnwrap(store.updateMessageAttachment(updated, conversationID: " c1 "))

        XCTAssertEqual(result.attachmentName, "demo.mp4")
        XCTAssertEqual(result.attachmentMeta, "video/mp4 · 4 MB")
        XCTAssertEqual(result.attachmentFileID, "file-video")
        XCTAssertEqual(result.attachmentSizeBytes, 4_194_304)
        XCTAssertEqual(result.attachmentPreviewURL, "https://example.test/preview")
        XCTAssertEqual(result.attachmentDownloadURL, "https://example.test/download")
        XCTAssertTrue(result.attachmentPreviewAvailable)
        XCTAssertTrue(result.attachmentDownloadAvailable)
        XCTAssertEqual(result.attachmentTransferProgress ?? -1, 0.66, accuracy: 0.001)
        XCTAssertEqual(result.attachmentMimeType, "video/mp4")
        XCTAssertEqual(result.attachmentCacheKey, "cache-video")
        XCTAssertEqual(result.attachmentVersion, "v2")
        XCTAssertEqual(result.attachmentChecksum, "checksum")
        XCTAssertEqual(result.attachmentMediaCategory, "video")
        XCTAssertEqual(result.attachmentExtension, "mp4")
        XCTAssertEqual(result.attachmentThumbnailURL, "https://example.test/thumb")
        XCTAssertEqual(result.attachmentPosterURL, "https://example.test/poster")
        XCTAssertEqual(result.attachmentCoverURL, "https://example.test/cover")
        XCTAssertEqual(result.attachmentPreviewKind, "video")
        XCTAssertEqual(result.attachmentContentDisposition, "inline")
        XCTAssertEqual(result.attachmentWidth, 1280)
        XCTAssertEqual(result.attachmentHeight, 720)
        XCTAssertEqual(result.attachmentDurationSeconds, 12.5)
        XCTAssertEqual(result.attachmentUploadStatus, "uploaded")
        XCTAssertEqual(store.conversations[0].lastMessage, "[视频] demo.mp4")
    }

    func testConversationStoreAttachmentMetadataStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, text: "report.pdf", kind: .file)
        message.attachmentFileID = "file-1"
        message.attachmentTransferProgress = 0.7
        message.attachmentName = "report.pdf"
        conversation.messages = [message]
        conversation.lastMessage = "[文件] report.pdf"
        store.conversations = [conversation]

        XCTAssertNil(store.setAttachmentFileID(" ", messageID: "m1", conversationID: "c1"))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: "m1", conversationID: " "))
        XCTAssertNil(store.setAttachmentFileID("file-2", messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: "m1", conversationID: " "))
        XCTAssertNil(store.updateAttachmentProgress(0.2, messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(makeMessage(id: " ", seq: 1, kind: .file), conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(makeMessage(id: "missing", seq: 1, kind: .file), conversationID: "c1"))
        XCTAssertNil(store.updateMessageAttachment(message, conversationID: " "))

        XCTAssertEqual(store.conversations[0].messages[0].attachmentFileID, "file-1")
        XCTAssertEqual(store.conversations[0].messages[0].attachmentTransferProgress ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(store.conversations[0].messages[0].attachmentName, "report.pdf")
        XCTAssertEqual(store.conversations[0].lastMessage, "[文件] report.pdf")
    }

    func testConversationStoreMessageActionStateReadsAndUpdatesPinnedAndFavorite() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        message.isFavorited = true
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertEqual(store.messagePinnedState(messageID: " m1 ", conversationID: " c1 "), false)
        XCTAssertEqual(store.messageFavoritedState(messageID: " m1 ", conversationID: " c1 "), true)
        XCTAssertTrue(store.setMessagePinned(messageID: " m1 ", conversationID: " c1 ", pinned: true))
        XCTAssertTrue(store.setMessageFavorited(messageID: " m1 ", conversationID: " c1 ", favorited: false))

        XCTAssertTrue(store.conversations[0].messages[0].isPinned)
        XCTAssertFalse(store.conversations[0].messages[0].isFavorited)
    }

    func testMessageReportActionOnlyShowsForOtherRemoteMessages() {
        let incoming = makeMessage(id: "remote-1", seq: 1, status: .sent, isOutgoing: false)
        let outgoing = makeMessage(id: "remote-2", seq: 2, status: .sent, isOutgoing: true)
        let local = makeMessage(id: "local_1", seq: 0, status: .sent, isOutgoing: false)
        let recalled = makeMessage(id: "remote-3", seq: 3, status: .recalled, isOutgoing: false)

        XCTAssertTrue(messageReportActionIsAvailable(message: incoming, isCurrentUserSender: false))
        XCTAssertFalse(messageReportActionIsAvailable(message: incoming, isCurrentUserSender: true))
        XCTAssertFalse(messageReportActionIsAvailable(message: outgoing, isCurrentUserSender: true))
        XCTAssertFalse(messageReportActionIsAvailable(message: local, isCurrentUserSender: false))
        XCTAssertFalse(messageReportActionIsAvailable(message: recalled, isCurrentUserSender: false))
    }

    func testMessageActionMenuPlacesReportLastAndDangerWhenAvailable() {
        let incoming = makeMessage(id: "remote-1", seq: 1, status: .sent, isOutgoing: false)

        let descriptors = messageActionMenuDescriptors(
            message: incoming,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: false,
            canReportMessage: true,
            canAdminDeleteForAll: true,
            recallDisabledReason: nil
        )

        XCTAssertEqual(descriptors.last?.kind, .report)
        XCTAssertEqual(descriptors.last?.title, "举报此消息")
        XCTAssertEqual(descriptors.last?.tone, .danger)
        XCTAssertEqual(descriptors.last?.showsDividerBefore, true)

        let ownDescriptors = messageActionMenuDescriptors(
            message: makeMessage(id: "remote-2", seq: 2, status: .sent, isOutgoing: true),
            canShowReadActions: true,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )
        XCTAssertFalse(ownDescriptors.contains { $0.kind == .report })
    }

    func testMessageActionMenuShowsFavoriteImmediatelyAfterPinForAssets() {
        var imageMessage = makeMessage(id: "remote-image", seq: 1, status: .sent, kind: .image)
        var descriptors = messageActionMenuDescriptors(
            message: imageMessage,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: true,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        XCTAssertEqual(Array(descriptors.map(\.kind).prefix(3)), [.reply, .pin, .favorite])
        XCTAssertEqual(descriptors.first { $0.kind == .favorite }?.title, "收藏")

        imageMessage.isFavorited = true
        descriptors = messageActionMenuDescriptors(
            message: imageMessage,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: true,
            canFavoriteAsset: true,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        XCTAssertEqual(descriptors.first { $0.kind == .favorite }?.title, "取消收藏")
        XCTAssertFalse(messageActionMenuDescriptors(
            message: makeMessage(id: "remote-text", seq: 2, status: .sent, kind: .text),
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: true,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: false,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        ).contains { $0.kind == .favorite })
    }

    func testMessageActionMenuKeepsIneligibleVoiceForwardVisibleDisabledWithExactReason() {
        let voice = makeMessage(
            id: "remote-voice",
            senderId: "other-user",
            seq: 1,
            status: .sent,
            isOutgoing: false,
            kind: .voice
        )

        let descriptors = messageActionMenuDescriptors(
            message: voice,
            canShowReadActions: false,
            readActionTitle: "已读列表",
            canForward: false,
            forwardDisabledReason: batchForwardVoiceOwnershipReason,
            canSaveAttachment: false,
            canFavoriteAsset: false,
            canReportMessage: true,
            canAdminDeleteForAll: false,
            recallDisabledReason: nil
        )

        let forward = descriptors.first { $0.kind == .forward }
        XCTAssertEqual(forward?.title, batchForwardVoiceOwnershipReason)
        XCTAssertEqual(forward?.disabledReason, batchForwardVoiceOwnershipReason)
        XCTAssertEqual(forward?.tone, .muted)
    }

    func testConversationStoreSetMessageReportStateUpdatesReason() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true)
        message.reportState = nil
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertTrue(store.setMessageReportState(messageID: " m1 ", conversationID: " c1 ", reason: "spam"))

        XCTAssertEqual(store.conversations[0].messages[0].reportState, "spam")
    }

    func testConversationStoreMessageActionStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, isOutgoing: true, isPinned: false)
        message.isFavorited = false
        message.reportState = nil
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertNil(store.messagePinnedState(messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.messagePinnedState(messageID: "m1", conversationID: " "))
        XCTAssertNil(store.messagePinnedState(messageID: "missing", conversationID: "c1"))
        XCTAssertNil(store.messageFavoritedState(messageID: " ", conversationID: "c1"))
        XCTAssertNil(store.messageFavoritedState(messageID: "m1", conversationID: " "))
        XCTAssertNil(store.messageFavoritedState(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.setMessagePinned(messageID: " ", conversationID: "c1", pinned: true))
        XCTAssertFalse(store.setMessagePinned(messageID: "m1", conversationID: " ", pinned: true))
        XCTAssertFalse(store.setMessagePinned(messageID: "missing", conversationID: "c1", pinned: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: " ", conversationID: "c1", favorited: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: "m1", conversationID: " ", favorited: true))
        XCTAssertFalse(store.setMessageFavorited(messageID: "missing", conversationID: "c1", favorited: true))
        XCTAssertFalse(store.setMessageReportState(messageID: " ", conversationID: "c1", reason: "spam"))
        XCTAssertFalse(store.setMessageReportState(messageID: "m1", conversationID: " ", reason: "spam"))
        XCTAssertFalse(store.setMessageReportState(messageID: "missing", conversationID: "c1", reason: "spam"))

        XCTAssertFalse(store.conversations[0].messages[0].isPinned)
        XCTAssertFalse(store.conversations[0].messages[0].isFavorited)
        XCTAssertNil(store.conversations[0].messages[0].reportState)
    }

    func testConversationStoreContactCardResendStateUpdatesMetaFailedAndSending() throws {
        let store = ConversationStore()
        let createdAt = Date(timeIntervalSince1970: 1_803_456_789)
        let readReceipt = makeReadReceipt(userID: "me")
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .contactCard)
        message.attachmentMeta = nil
        message.createdAt = nil
        message.readBy = []
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertTrue(store.setContactCardAttachmentMeta(messageID: " m1 ", conversationID: " c1 ", contactID: " contact-1 "))
        XCTAssertTrue(store.markMessageResendFailed(messageID: " m1 ", conversationID: " c1 "))
        let prepared = try XCTUnwrap(store.prepareMessageForResend(
            messageID: " m1 ",
            conversationID: " c1 ",
            createdAt: createdAt,
            readBy: [readReceipt]
        ))

        XCTAssertEqual(prepared.attachmentMeta, "contact-1")
        XCTAssertEqual(prepared.status, .sending)
        XCTAssertEqual(prepared.createdAt, createdAt)
        XCTAssertEqual(prepared.readBy, [readReceipt])
        XCTAssertEqual(store.conversations[0].messages[0].attachmentMeta, "contact-1")
        XCTAssertEqual(store.conversations[0].messages[0].status, .sending)
        XCTAssertEqual(store.conversations[0].messages[0].createdAt, createdAt)
        XCTAssertEqual(store.conversations[0].messages[0].readBy, [readReceipt])
    }

    func testConversationStoreContactCardResendStateSkipsInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var contactCard = makeMessage(id: "m1", seq: 1, status: .failed, isOutgoing: true, kind: .contactCard)
        contactCard.attachmentMeta = "old-contact"
        var text = makeMessage(id: "m2", seq: 2, status: .failed, isOutgoing: true, kind: .text)
        text.attachmentMeta = "text-meta"
        conversation.messages = [contactCard, text]
        store.conversations = [conversation]

        XCTAssertFalse(store.markMessageResendFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markMessageResendFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markMessageResendFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: " ", conversationID: "c1", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m1", conversationID: " ", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m1", conversationID: "c1", contactID: " "))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "missing", conversationID: "c1", contactID: "contact-1"))
        XCTAssertFalse(store.setContactCardAttachmentMeta(messageID: "m2", conversationID: "c1", contactID: "contact-1"))
        XCTAssertNil(store.prepareMessageForResend(messageID: " ", conversationID: "c1", readBy: []))
        XCTAssertNil(store.prepareMessageForResend(messageID: "m1", conversationID: " ", readBy: []))
        XCTAssertNil(store.prepareMessageForResend(messageID: "missing", conversationID: "c1", readBy: []))

        XCTAssertEqual(store.conversations[0].messages[0].attachmentMeta, "old-contact")
        XCTAssertEqual(store.conversations[0].messages[0].status, .failed)
        XCTAssertEqual(store.conversations[0].messages[1].attachmentMeta, "text-meta")
    }

    func testConversationStoreMarkMessageFailedUpdatesStatusAndLatestPreview() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.lastMessage = "second"
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, text: "first"),
            makeMessage(id: "m2", seq: 2, status: .sent, text: "second")
        ]
        store.conversations = [conversation]

        XCTAssertTrue(store.markMessageFailed(messageID: " m2 ", conversationID: " c1 "))

        XCTAssertEqual(store.conversations[0].messages[1].status, .failed)
        XCTAssertEqual(store.conversations[0].lastMessage, "first")
    }

    func testConversationStoreRemoveMessageDeletesTargetAndUpdatesLatestPreview() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        conversation.lastMessage = "second"
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, status: .sent, text: "first"),
            makeMessage(id: "m2", seq: 2, status: .sent, text: "second")
        ]
        store.conversations = [conversation]

        XCTAssertTrue(store.removeMessage(messageID: " m2 ", conversationID: " c1 "))

        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversations[0].lastMessage, "first")
    }

    func testConversationStoreMessageFailureAndRemovalSkipInvalidOrMissingTargets() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.lastMessage = "first"
        conversation.messages = [makeMessage(id: "m1", seq: 1, status: .sent, text: "first")]
        store.conversations = [conversation]

        XCTAssertFalse(store.markMessageFailed(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.markMessageFailed(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.markMessageFailed(messageID: "missing", conversationID: "c1"))
        XCTAssertFalse(store.removeMessage(messageID: " ", conversationID: "c1"))
        XCTAssertFalse(store.removeMessage(messageID: "m1", conversationID: " "))
        XCTAssertFalse(store.removeMessage(messageID: "missing", conversationID: "c1"))

        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])
        XCTAssertEqual(store.conversations[0].messages[0].status, .sent)
        XCTAssertEqual(store.conversations[0].lastMessage, "first")
    }

    func testConversationStoreResolveGroupInviteApprovalMessagesUpdatesAllMatches() throws {
        let store = ConversationStore()
        var systemConversation = makeConversation(id: "system", kind: .system, unread: 0, lastMsgSeq: 2, lastReadSeq: 1)
        var firstMatch = makeMessage(id: "m1", seq: 1, status: .sent, kind: .system)
        firstMatch.groupInviteApproval = makeGroupInviteApproval(requestID: " request-1 ", resultText: "待处理")
        var otherRequest = makeMessage(id: "m2", seq: 2, status: .sent, kind: .system)
        otherRequest.groupInviteApproval = makeGroupInviteApproval(requestID: "request-2")
        systemConversation.messages = [firstMatch, otherRequest]
        var groupConversation = makeConversation(id: "group-1", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var secondMatch = makeMessage(id: "m3", seq: 1, status: .sent, kind: .system)
        secondMatch.groupInviteApproval = makeGroupInviteApproval(requestID: "request-1")
        groupConversation.messages = [secondMatch]
        store.conversations = [systemConversation, groupConversation]

        let updatedCount = store.resolveGroupInviteApprovalMessages(
            requestID: " request-1 ",
            status: "approved",
            approverName: "管理员",
            approverAccountID: "admin-1",
            decidedAt: "10:30",
            resultText: "已通过"
        )

        XCTAssertEqual(updatedCount, 2)
        let firstResolved = try XCTUnwrap(store.conversations[0].messages[0].groupInviteApproval)
        XCTAssertEqual(firstResolved.status, "approved")
        XCTAssertEqual(firstResolved.resultText, "已通过")
        XCTAssertTrue(firstResolved.processed)
        XCTAssertEqual(firstResolved.approverName, "管理员")
        XCTAssertEqual(firstResolved.approverAccountID, "admin-1")
        XCTAssertEqual(firstResolved.decidedAt, "10:30")
        XCTAssertFalse(firstResolved.canApprove)
        XCTAssertFalse(firstResolved.canReject)
        let secondResolved = try XCTUnwrap(store.conversations[1].messages[0].groupInviteApproval)
        XCTAssertEqual(secondResolved.status, "approved")
        XCTAssertTrue(secondResolved.processed)
        let untouched = try XCTUnwrap(store.conversations[0].messages[1].groupInviteApproval)
        XCTAssertEqual(untouched.status, "pending")
        XCTAssertFalse(untouched.processed)
    }

    func testConversationStoreResolveGroupInviteApprovalMessagesSkipsEmptyOrMissingRequestID() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "system", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var message = makeMessage(id: "m1", seq: 1, status: .sent, kind: .system)
        message.groupInviteApproval = makeGroupInviteApproval(requestID: "request-1")
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertEqual(store.resolveGroupInviteApprovalMessages(requestID: " ", status: "approved", resultText: "已通过"), 0)
        XCTAssertEqual(store.resolveGroupInviteApprovalMessages(requestID: "missing", status: "approved", resultText: "已通过"), 0)

        let approval = try XCTUnwrap(store.conversations[0].messages[0].groupInviteApproval)
        XCTAssertEqual(approval.status, "pending")
        XCTAssertFalse(approval.processed)
        XCTAssertEqual(approval.resultText, "")
        XCTAssertTrue(approval.canApprove)
        XCTAssertTrue(approval.canReject)
    }

    func testConversationStoreReadSeqHelpersKeepMaximum() {
        let store = ConversationStore()

        store.rememberRead(key: "direct|c1", readSeq: 7)
        store.rememberRead(key: "direct|c1", readSeq: 4)
        store.rememberRead(key: "direct|c1", readSeq: 11)
        store.rememberRead(key: "", readSeq: 30)
        store.rememberRead(key: "direct|c2", readSeq: 0)

        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c1"), 11)
        XCTAssertEqual(store.locallyReadSeq(forKey: ""), 0)
        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c2"), 0)
        XCTAssertTrue(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 11))
        XCTAssertFalse(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 12))
        XCTAssertFalse(store.isLocallyReadThrough(key: "direct|c1", lastMessageSeq: 0))
    }

    func testConversationStoreReadWatermarkRequiresExactScopeAndKeepsMaximum() throws {
        let store = ConversationStore()
        let watermark = try XCTUnwrap(ConversationStore.ReadWatermark(
            eventID: "read-1",
            tenantID: " tenant-a ",
            imUID: " user-a ",
            appID: " app-ios ",
            channelID: " c1 ",
            channelType: " Direct ",
            lastReadSeq: 7,
            occurredAt: "2026-08-26T00:00:00Z"
        ))
        let sameScopeLower = try XCTUnwrap(ConversationStore.ReadWatermark(
            eventID: "read-2",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 4
        ))
        let otherApp = ConversationStore.ReadWatermarkScope(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "other-app",
            channelID: "c1",
            channelType: "direct"
        )

        XCTAssertEqual(store.rememberReadWatermark(watermark), 7)
        XCTAssertEqual(store.rememberReadWatermark(sameScopeLower), 7)
        XCTAssertEqual(store.scopedReadWatermarkSeq(for: watermark.scope), 7)
        XCTAssertEqual(store.scopedReadWatermarkSeq(for: otherApp), 0)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: watermark.scope), 7)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: otherApp), 0)
        XCTAssertEqual(store.locallyReadSeq(forKey: "direct|c1"), 0)
        store.rememberRead(key: "direct|c1", readSeq: 9)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: nil), 9)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: watermark.scope), 7)
        XCTAssertEqual(store.effectiveReadSeq(readStateKey: "direct|c1", scope: otherApp), 0)
        XCTAssertNil(ConversationStore.ReadWatermark(
            eventID: "missing-app",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: " ",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 8
        ))
        XCTAssertNil(ConversationStore.ReadWatermark(
            eventID: "unsupported-channel",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "unknown",
            lastReadSeq: 8
        ))
    }

    func testConversationStoreLateRealtimeMessageAtReadWatermarkDoesNotUnreadOrSound() throws {
        let store = ConversationStore()
        var previous = makeConversation(id: "c1", kind: .direct, unread: 0, lastMsgSeq: 10, lastReadSeq: 10)
        previous.hasUnreadReaction = false
        previous.unreadReactionCount = 0
        previous.messages = [makeMessage(id: "m10", seq: 10)]
        store.conversations = [previous]
        let lateMessage = makeMessage(id: "m10-replay", senderId: "peer", seq: 10, isOutgoing: false)

        let merge = store.mergeMappedRemoteMessages(
            previous: previous,
            mappedRemoteMessages: [
                ConversationStore.MappedRemoteMessage(
                    remote: try decodeRemoteMessage(remoteMessageJSON(id: "m10-replay", channelID: "c1", channelType: "direct", seq: 10)),
                    message: lateMessage,
                    clientMessageIDs: [],
                    isRemoteFromCurrentUser: false,
                    matchedLocalID: nil
                )
            ],
            readReceiptsEnabled: true,
            fromRealtime: true,
            effectiveReadSeq: 10
        )
        let applied = store.applyMergedRemoteMessagesConversation(
            channelID: "c1",
            kind: .direct,
            previous: previous,
            title: "Direct",
            subtitle: "单聊",
            participants: [],
            messages: merge.messages,
            latestMessage: lateMessage,
            incomingRealtimeMessages: merge.incomingRealtimeMessages,
            latestKnownSeq: merge.latestKnownSeq,
            fromRealtime: true,
            isActiveRealtimeConversation: false,
            canAutoReadActiveRealtimeConversation: false,
            memberCount: 0,
            accentHex: 0,
            avatarURL: "",
            avatarVersion: "",
            avatarUpdatedAt: "",
            effectiveReadSeq: 10
        )

        XCTAssertTrue(merge.incomingRealtimeMessages.isEmpty)
        XCTAssertFalse(applied.shouldPlayIncomingSound)
        XCTAssertEqual(applied.conversation.unread, 0)
        XCTAssertEqual(applied.conversation.lastReadSeq, 10)
        XCTAssertEqual(applied.conversation.lastMessage, previous.lastMessage)
        XCTAssertEqual(applied.conversation.sortTimestamp, previous.sortTimestamp)
    }

    func testConversationStoreMessageSyncLifecycleMatchesAppStateBehavior() {
        let store = ConversationStore()
        store.setHistoryMessage(conversationID: "c1", message: "stale")

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertTrue(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertEqual(store.historyLoadingConversationIDs(), ["c1"])
        XCTAssertTrue(store.hasHistoryLoadingIDs())
        XCTAssertTrue(store.isMessageSyncInFlight(historyKey: "scope|c1"))

        store.setHistoryMessage(conversationID: "c1", message: "busy")
        XCTAssertFalse(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))

        store.finishMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: true)
        XCTAssertFalse(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertFalse(store.hasHistoryLoadingIDs())
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: "scope|c1"))
    }

    func testConversationStoreHistoryAndDirectStatusFacadesManageSnapshots() {
        let store = ConversationStore()

        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
        XCTAssertFalse(store.hasApplyingFriendIDs())

        store.setHistoryMessage(conversationID: "c1", message: "history")
        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "history")
        XCTAssertEqual(store.historyMessagesByConversationID(), ["c1": "history"])
        XCTAssertTrue(store.hasHistoryMessages())
        XCTAssertEqual(store.directDisabledMessage(conversationID: "c1"), "disabled")
        XCTAssertEqual(store.directDisabledMessagesByConversationID(), ["c1": "disabled"])
        XCTAssertTrue(store.hasDirectDisabledMessages())

        XCTAssertTrue(store.beginApplyingFriend(conversationID: "c1"))
        XCTAssertFalse(store.beginApplyingFriend(conversationID: "c1"))
        XCTAssertTrue(store.isApplyingFriend(conversationID: "c1"))
        XCTAssertEqual(store.applyingFriendConversationIDs(), ["c1"])
        XCTAssertTrue(store.hasApplyingFriendIDs())

        store.finishApplyingFriend(conversationID: "c1")
        XCTAssertFalse(store.isApplyingFriend(conversationID: "c1"))
        XCTAssertFalse(store.hasApplyingFriendIDs())

        store.clearHistoryAndDirectDisabledMessages(conversationID: "c1")
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "c1"))
        XCTAssertFalse(store.hasHistoryMessages())
        XCTAssertFalse(store.hasDirectDisabledMessages())
    }

    func testConversationStoreDirectFriendRequestContextLifecycle() {
        let store = ConversationStore()
        let context = DirectFriendRequestContext(
            targetUID: "u1",
            canApplyFriend: true,
            friendRequestStatus: "rejected",
            reasonCode: "friendship_required"
        )

        XCTAssertFalse(store.hasDirectFriendRequestContexts())
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))

        store.setDirectFriendRequestContext(conversationID: "c1", context: context)
        XCTAssertTrue(store.hasDirectFriendRequestContexts())
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.targetUID, "u1")
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.actionTitle, "添加好友")
        XCTAssertEqual(store.directFriendRequestContext(conversationID: "c1")?.allowsApply, true)

        store.clearDirectFriendRequestContext(conversationID: "c1")
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))
        XCTAssertFalse(store.hasDirectFriendRequestContexts())
    }

    func testConversationStoreConversationPollingPlanUsesActiveFlagAndInFlightState() {
        let store = ConversationStore()
        store.conversations = [
            makeConversation(id: "c1", unread: 0, lastMsgSeq: 10, lastReadSeq: 0)
        ]
        var historyKeyInputs: [String] = []

        let idlePlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { conversation in
                historyKeyInputs.append(conversation.id)
                return " scope|c1 "
            }
        )

        XCTAssertEqual(historyKeyInputs, ["c1"])
        XCTAssertEqual(
            idlePlan,
            ConversationStore.ConversationPollingPlan(
                conversationID: "c1",
                historyKey: "scope|c1",
                shouldPollActiveConversation: true,
                isMessageSyncInFlight: false
            )
        )
        XCTAssertTrue(idlePlan.shouldPoll)

        let realtimeConnectedPlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: false,
            historyKeyForConversation: { _ in "scope|c1" }
        )
        XCTAssertFalse(realtimeConnectedPlan.shouldPoll)

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        let inFlightPlan = store.conversationPollingPlan(
            conversationID: "c1",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { _ in "scope|c1" }
        )
        XCTAssertTrue(inFlightPlan.isMessageSyncInFlight)
        XCTAssertFalse(inFlightPlan.shouldPoll)

        let missingConversationPlan = store.conversationPollingPlan(
            conversationID: "missing",
            shouldPollActiveConversation: true,
            historyKeyForConversation: { _ in
                XCTFail("Missing conversations should not request a history key")
                return "unused"
            }
        )
        XCTAssertEqual(
            missingConversationPlan,
            ConversationStore.ConversationPollingPlan(
                conversationID: "missing",
                historyKey: "",
                shouldPollActiveConversation: true,
                isMessageSyncInFlight: false
            )
        )
        XCTAssertTrue(missingConversationPlan.shouldPoll)
    }

    func testConversationStoreMessageSyncUsesInjectedEngine() {
        let engine = DefaultSyncEngine()
        let store = ConversationStore(messageSyncEngine: engine)
        let request = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "c1",
            historyKey: "scope|c1",
            reason: "assert"
        )

        XCTAssertTrue(store.beginMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false))
        XCTAssertTrue(engine.isInFlight(request))

        store.finishMessageSync(historyKey: "scope|c1", conversationID: "c1", showLoadingIndicator: false)
        XCTAssertFalse(engine.isInFlight(request))
    }

    func testConversationStoreOlderHistoryLoadLifecycleThrottlesRequests() {
        let store = ConversationStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        store.setHistoryMessage(conversationID: "c1", message: "old")

        XCTAssertTrue(store.beginOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1", now: startedAt, throttleInterval: 1))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertTrue(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertTrue(store.hasHistoryLoadRequestTimes())

        store.finishOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertFalse(store.isHistoryLoading(conversationID: "c1"))
        XCTAssertFalse(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(0.5),
            throttleInterval: 1
        ))
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(1.1),
            throttleInterval: 1
        ))
        XCTAssertFalse(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(2.2),
            throttleInterval: 1
        ))
        store.finishOlderHistoryLoad(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertTrue(store.beginOlderHistoryLoad(
            historyKey: "scope|c1",
            conversationID: "c1",
            now: startedAt.addingTimeInterval(2.2),
            throttleInterval: 1
        ))
    }

    func testConversationStoreOlderHistoryResultStateTransitions() {
        let store = ConversationStore()

        store.markHistoryUnavailable(historyKey: "scope|empty", conversationID: "empty", message: "empty")
        XCTAssertTrue(store.hasReachedHistoryStart(historyKey: "scope|empty"))
        XCTAssertEqual(store.historyMessage(conversationID: "empty"), "empty")

        store.markOlderHistoryNeedsContinue(
            historyKey: "scope|c1",
            conversationID: "c1",
            nextBackfillAfterSeq: 120,
            pageLimit: 100,
            message: "continue"
        )
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: 0), 20)
        XCTAssertTrue(store.hasHistoryBackfillAfterSeqs())
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "continue")

        store.markOlderHistoryReachedStart(historyKey: "scope|c1", conversationID: "c1", message: "done")
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: -1), -1)
        XCTAssertFalse(store.hasHistoryBackfillAfterSeqs())
        XCTAssertTrue(store.hasReachedHistoryStart(historyKey: "scope|c1"))
        XCTAssertTrue(store.hasHistoryReachedStartKeys())
        XCTAssertEqual(store.historyMessage(conversationID: "c1"), "done")

        store.setDirectDisabledMessage(conversationID: "c1", message: "disabled")
        store.setHistoryMessage(conversationID: "c1", message: "done")
        store.setDirectFriendRequestContext(
            conversationID: "c1",
            context: DirectFriendRequestContext(
                targetUID: "u1",
                canApplyFriend: false,
                friendRequestStatus: "pending",
                reasonCode: "friendship_required"
            )
        )
        store.markOlderHistoryApplied(historyKey: "scope|c1", conversationID: "c1")
        XCTAssertEqual(store.historyBackfillAfterSeq(historyKey: "scope|c1", defaultValue: -1), -1)
        XCTAssertFalse(store.hasReachedHistoryStart(historyKey: "scope|c1"))
        XCTAssertNil(store.historyMessage(conversationID: "c1"))
        XCTAssertNil(store.directDisabledMessage(conversationID: "c1"))
        XCTAssertNil(store.directFriendRequestContext(conversationID: "c1"))
    }

    func testConversationStoreRecentHistoryAfterSeqUsesLatestKnownSequence() {
        let store = ConversationStore()
        let emptyConversation = makeConversation(id: "empty", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        let remoteLatestConversation = makeConversation(id: "remote", unread: 0, lastMsgSeq: 130, lastReadSeq: 0)
        var localLatestConversation = makeConversation(id: "local", unread: 0, lastMsgSeq: 80, lastReadSeq: 0)
        localLatestConversation.messages = [
            makeMessage(id: "m120", seq: 120),
            makeMessage(id: "m140", seq: 140)
        ]

        XCTAssertEqual(store.recentHistoryAfterSeq(for: emptyConversation, limit: 100), 0)
        XCTAssertEqual(store.recentHistoryAfterSeq(for: remoteLatestConversation, limit: 100), 30)
        XCTAssertEqual(store.recentHistoryAfterSeq(for: localLatestConversation, limit: 100), 40)
    }

    func testConversationStoreNewerHistoryTargetUsesNewestLoadedSequence() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "jumped", unread: 0, lastMsgSeq: 1_000, lastReadSeq: 0)
        conversation.messages = (451...500).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let target = try XCTUnwrap(store.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: "scope|jumped",
            limit: 20
        ))

        XCTAssertEqual(target.historyKey, "scope|jumped")
        XCTAssertEqual(target.conversationID, "jumped")
        XCTAssertEqual(target.afterSeq, 500)
        XCTAssertEqual(target.latestKnownSeq, 1_000)
        XCTAssertEqual(target.limit, 20)
    }

    func testConversationStoreNewerHistoryTargetSkipsWhenLatestWindowLoaded() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "latest", unread: 0, lastMsgSeq: 500, lastReadSeq: 0)
        conversation.messages = (481...500).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        XCTAssertNil(store.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: "scope|latest",
            limit: 20
        ))
    }

    func testConversationStoreInitialMessageSyncWindowsUsesLatestWindowForLargeUnreadEntry() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "large_unread", unread: 500, lastMsgSeq: 1_000, lastReadSeq: 500)
        conversation.firstUnreadSeq = 501
        conversation.firstUnreadMessageID = "m501"
        conversation.unreadAnchorSeq = 501
        conversation.messages = [makeMessage(id: "m1000", seq: 1_000)]

        let windows = store.initialMessageSyncWindows(for: conversation, limit: 100)

        XCTAssertEqual(windows, [
            ConversationStore.MessageSyncWindow(afterSeq: 900, limit: 100)
        ])
    }

    func testConversationStoreMessageSyncPlanUsesRemoteHistoryWindowsForUnreadEntry() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "large_unread", unread: 500, lastMsgSeq: 1_000, lastReadSeq: 500)
        conversation.firstUnreadSeq = 501
        conversation.unreadAnchorSeq = 501
        conversation.messages = [makeMessage(id: "m1000", seq: 1_000)]

        let plan = store.messageSyncPlan(
            for: conversation,
            historyKey: "scope|large_unread",
            force: false,
            latestHistoryWindowLimit: 100
        )

        XCTAssertEqual(plan, .remoteHistory(historyKey: "scope|large_unread", windows: [
            ConversationStore.MessageSyncWindow(afterSeq: 900, limit: 100)
        ]))
    }

    func testConversationStoreMessageSyncPlanUsesSidecarsOnlyForCompleteHistory() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]

        XCTAssertEqual(
            store.messageSyncPlan(
                for: conversation,
                historyKey: "scope|complete",
                force: false,
                latestHistoryWindowLimit: 100
            ),
            .sidecarsOnly
        )
        XCTAssertEqual(
            store.messageSyncPlan(
                for: conversation,
                historyKey: "scope|complete",
                force: true,
                latestHistoryWindowLimit: 100
            ),
            .remoteHistory(historyKey: "scope|complete", windows: [
                ConversationStore.MessageSyncWindow(afterSeq: 0, limit: 100)
            ])
        )
    }

    func testChatInitialScrollAnchorUsesBottomForLargeUnreadEntry() throws {
        let boundaryMessages = (481...580).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }
        let messages = boundaryMessages + [makeMessage(id: "m1000", seq: 1_000)]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: messages.count,
            lastReadSeq: 500,
            firstUnreadMessageID: "m501",
            firstUnreadSeq: 501,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatInitialScrollAnchorUsesBottomWhenUnreadBoundaryIsNewerThanLoadedWindow() throws {
        let oldWindowMessages = (21...40).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: oldWindowMessages,
            unreadCount: 3,
            lastReadSeq: 500,
            firstUnreadMessageID: "m38",
            firstUnreadSeq: 501,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }

    func testChatUnreadDividerUsesFirstUnreadSequenceInsideLoadedWindow() {
        let messages = (498...505).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: messages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 501,
            lastReadSeq: 500,
            unreadCount: 5
        )

        XCTAssertEqual(dividerID, "m501")
    }

    func testChatUnreadDividerDoesNotPinToTrimmedLatestWindowTop() {
        let latestWindowMessages = (901...1_000).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: latestWindowMessages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 501,
            lastReadSeq: 500,
            unreadCount: 500
        )

        XCTAssertNil(dividerID)
    }

    func testChatUnreadDividerFallsBackToLastReadSequenceWhenRemoteAnchorMissing() {
        let messages = (498...505).map { seq in
            makeMessage(id: "m\(seq)", seq: Int64(seq))
        }

        let dividerID = chatFirstUnreadMessageIDForDivider(
            messages: messages,
            firstUnreadMessageID: "",
            firstUnreadSeq: 0,
            lastReadSeq: 500,
            unreadCount: 5
        )

        XCTAssertEqual(dividerID, "m501")
    }

    func testChatTimelineRenderingFiltersPinnedContextOnlyMessagesFromAnchorInput() throws {
        var oldPinned = makeMessage(id: "pinned-old", seq: 11, text: "old pinned")
        oldPinned.isPinned = true
        oldPinned.isPinnedContextOnly = true
        let latestWindow = [
            makeMessage(id: "m430", seq: 430, text: "last read"),
            makeMessage(id: "m431", seq: 431, text: "unread 1"),
            makeMessage(id: "m432", seq: 432, text: "unread 2"),
            makeMessage(id: "m433", seq: 433, text: "unread 3")
        ]

        let timelineMessages = chatTimelineMessagesForRendering([oldPinned] + latestWindow)
        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: timelineMessages,
            unreadCount: 3,
            lastReadSeq: 430,
            firstUnreadMessageID: "m431",
            firstUnreadSeq: 431,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(timelineMessages.map(\.id), ["m430", "m431", "m432", "m433"])
        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertFalse(anchor.anchorsLastReadMessage)
    }

    func testConversationStorePinnedMessageSnapshotMergesContextMessagesAndUpdatesStore() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 20, lastReadSeq: 0)
        var staleContext = makeMessage(id: "stale", seq: 2, isPinned: true, text: "stale pinned")
        staleContext.isPinnedContextOnly = true
        var oldPinned = makeMessage(id: "old", seq: 4, isPinned: true, text: "old pinned")
        oldPinned.isPinnedContextOnly = false
        var unpinned = makeMessage(id: "unpinned", seq: 12, isPinned: true, text: "was pinned")
        unpinned.isPinnedContextOnly = false
        conversation.messages = [
            staleContext,
            oldPinned,
            makeMessage(id: "m10", seq: 10, text: "timeline 10"),
            unpinned,
            makeMessage(id: "m20", seq: 20, text: "timeline 20")
        ]
        store.conversations = [conversation]

        let newPinned = makeMessage(id: "new", seq: 15, text: "new pinned")
        let recalled = makeMessage(id: "recalled", seq: 18, text: "recalled pinned")
        let updated = try XCTUnwrap(store.applyPinnedMessageSnapshot([
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: " old ",
                status: "pinned",
                message: makeMessage(id: "old", seq: 4, text: "old pinned")
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "new",
                status: "pinned",
                message: newPinned
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "stale",
                status: "deleted",
                message: staleContext
            ),
            ConversationStore.PinnedMessageSnapshotEntry(
                messageID: "recalled",
                status: "recalled",
                message: recalled
            )
        ], conversationID: " c1 "))

        XCTAssertEqual(updated.messages.map(\.id), ["old", "m10", "unpinned", "new", "m20"])
        let mergedOld = try XCTUnwrap(updated.messages.first { $0.id == "old" })
        XCTAssertTrue(mergedOld.isPinned)
        XCTAssertTrue(mergedOld.isPinnedContextOnly)
        let mergedUnpinned = try XCTUnwrap(updated.messages.first { $0.id == "unpinned" })
        XCTAssertFalse(mergedUnpinned.isPinned)
        XCTAssertFalse(mergedUnpinned.isPinnedContextOnly)
        let mergedNew = try XCTUnwrap(updated.messages.first { $0.id == "new" })
        XCTAssertTrue(mergedNew.isPinned)
        XCTAssertTrue(mergedNew.isPinnedContextOnly)
        XCTAssertNil(updated.messages.first { $0.id == "stale" })
        XCTAssertNil(updated.messages.first { $0.id == "recalled" })
        XCTAssertEqual(store.conversations[0].messages.map(\.id), updated.messages.map(\.id))
    }

    func testConversationStorePinnedMessageSnapshotSkipsMissingConversation() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "m1", seq: 1, isPinned: true, text: "pinned")
        message.isPinnedContextOnly = true
        conversation.messages = [message]
        store.conversations = [conversation]

        XCTAssertNil(store.applyPinnedMessageSnapshot([], conversationID: " "))
        XCTAssertNil(store.applyPinnedMessageSnapshot([], conversationID: "missing"))

        XCTAssertEqual(store.conversations[0].messages.map(\.id), ["m1"])
        XCTAssertTrue(store.conversations[0].messages[0].isPinned)
        XCTAssertTrue(store.conversations[0].messages[0].isPinnedContextOnly)
    }

    func testConversationStoreOldestConfirmedMessageSeqIgnoresTransientAndPinnedBoundary() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", unread: 0, lastMsgSeq: 20, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "local_1", seq: 1),
            makeMessage(id: "sending", seq: 2, status: .sending),
            makeMessage(id: "failed", seq: 3, status: .failed),
            makeMessage(id: "pinned", seq: 4, isPinned: true),
            makeMessage(id: "m8", seq: 8),
            makeMessage(id: "m10", seq: 10)
        ]

        XCTAssertEqual(store.oldestConfirmedMessageSeq(in: conversation), 8)

        conversation.messages = [
            makeMessage(id: "pinned-only", seq: 4, isPinned: true)
        ]
        XCTAssertEqual(store.oldestConfirmedMessageSeq(in: conversation), 4)

        conversation.messages = [
            makeMessage(id: "local_2", seq: 5),
            makeMessage(id: "sending-2", seq: 6, status: .sending),
            makeMessage(id: "failed-2", seq: 7, status: .failed)
        ]
        XCTAssertNil(store.oldestConfirmedMessageSeq(in: conversation))
    }

    func testConversationStoreUsableRemoteHistoryRequiresRecentConfirmedWindow() {
        let store = ConversationStore()
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var stale = makeConversation(id: "stale", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        stale.messages = complete.messages
        var sparse = makeConversation(id: "sparse", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        sparse.messages = [
            makeMessage(id: "m4", seq: 4),
            makeMessage(id: "m5", seq: 5)
        ]

        XCTAssertTrue(store.hasUsableRemoteHistory(for: complete))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: stale))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: sparse))
    }

    func testConversationStoreUsableRemoteHistoryIgnoresDeletedAndRecalledMessages() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "c1", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m3", seq: 3)
        ]
        var deletedOnly = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        deletedOnly.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true)
        ]

        XCTAssertFalse(store.hasUsableRemoteHistory(for: conversation))
        XCTAssertFalse(store.hasUsableRemoteHistory(for: deletedOnly))
    }

    func testConversationStoreHistoryHydrationRequiresCompleteUsableWindow() {
        let store = ConversationStore()
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var deletedOnly = makeConversation(id: "deleted", kind: .group, unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        deletedOnly.messages = [
            makeMessage(id: "m1", seq: 1, status: .recalled, isDeletedLocally: true),
            makeMessage(id: "m2", seq: 2, status: .recalled, isDeletedLocally: true)
        ]
        var sparse = makeConversation(id: "sparse", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        sparse.messages = [
            makeMessage(id: "m4", seq: 4),
            makeMessage(id: "m5", seq: 5)
        ]

        XCTAssertFalse(store.needsHistoryHydration(local: complete, remoteLatestSeq: 3, remoteLastMessageID: "m3"))
        XCTAssertTrue(store.needsHistoryHydration(local: nil, remoteLatestSeq: 3, remoteLastMessageID: "m3"))
        XCTAssertTrue(store.needsHistoryHydration(local: complete, remoteLatestSeq: 4, remoteLastMessageID: "m4"))
        XCTAssertTrue(store.needsHistoryHydration(local: complete, remoteLatestSeq: 3, remoteLastMessageID: "missing"))
        XCTAssertTrue(store.needsHistoryHydration(local: deletedOnly, remoteLatestSeq: 2, remoteLastMessageID: "m2"))
        XCTAssertTrue(store.needsHistoryHydration(local: sparse, remoteLatestSeq: 5, remoteLastMessageID: "m5"))
    }

    func testConversationStoreHistoryPrefetchTargetsFilterSortAndExplainCandidates() throws {
        let store = ConversationStore()
        var complete = makeConversation(id: "complete", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        complete.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m2", seq: 2),
            makeMessage(id: "m3", seq: 3)
        ]
        var activeLocal = makeConversation(id: "active-local", kind: .group, unread: 0, lastMsgSeq: 4, lastReadSeq: 0)
        activeLocal.messages = [makeMessage(id: "a4", seq: 4)]
        var unreadLocal = makeConversation(id: "unread-local", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        unreadLocal.messages = [makeMessage(id: "u1", seq: 1)]
        var latestLocal = makeConversation(id: "latest-local", kind: .group, unread: 0, lastMsgSeq: 5, lastReadSeq: 0)
        latestLocal.messages = [makeMessage(id: "l5", seq: 5)]

        let completeRemote = try decodeRemoteConversation("""
        {"channel_id":"complete","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let activeRemote = try decodeRemoteConversation("""
        {"channel_id":"active","channel_type":"group","last_msg_seq":5,"unread_count":0}
        """)
        let unreadRemote = try decodeRemoteConversation("""
        {"channel_id":"unread","channel_type":"group","last_msg_seq":4,"unread_count":3}
        """)
        let latestRemote = try decodeRemoteConversation("""
        {"channel_id":"latest","channel_type":"group","last_msg_seq":9,"unread_count":0}
        """)

        let targets = store.historyPrefetchTargets(
            candidates: [
                ConversationStore.HistoryPrefetchCandidate(
                    remote: completeRemote,
                    channelID: "complete",
                    local: complete,
                    isActive: false,
                    latestSeq: 3,
                    sortTimestamp: 400,
                    logID: "complete"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: latestRemote,
                    channelID: "latest",
                    local: latestLocal,
                    isActive: false,
                    latestSeq: 9,
                    sortTimestamp: 900,
                    logID: "latest"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: unreadRemote,
                    channelID: "unread",
                    local: unreadLocal,
                    isActive: false,
                    latestSeq: 4,
                    sortTimestamp: 100,
                    logID: "unread"
                ),
                ConversationStore.HistoryPrefetchCandidate(
                    remote: activeRemote,
                    channelID: "active",
                    local: activeLocal,
                    isActive: true,
                    latestSeq: 5,
                    sortTimestamp: 50,
                    logID: "active"
                )
            ],
            limit: 3
        )

        XCTAssertEqual(targets.map(\.channelID), ["active", "unread", "latest"])
        XCTAssertEqual(targets.map(\.reason), ["active", "unread", "latest_seq"])
        XCTAssertEqual(
            targets.map(\.summaryFragment),
            [
                "active#seq5#ts50#active",
                "unread#seq4#ts100#unread",
                "latest#seq9#ts900#latest_seq"
            ]
        )
    }

    func testConversationStoreHistoryPrefetchExecutionPlanBuildsBatchesAndFetchWindows() throws {
        let store = ConversationStore()
        let firstRemote = try decodeRemoteConversation("""
        {"channel_id":"first","channel_type":"group","last_msg_seq":120,"unread_count":0}
        """)
        let secondRemote = try decodeRemoteConversation("""
        {"channel_id":"second","channel_type":"group","last_msg_seq":20,"unread_count":0}
        """)
        let thirdRemote = try decodeRemoteConversation("""
        {"channel_id":"third","channel_type":"group","last_msg_seq":60,"unread_count":0}
        """)

        let targets = [
            ConversationStore.HistoryPrefetchTarget(
                remote: firstRemote,
                channelID: "first",
                reason: "unread",
                latestSeq: 120,
                sortTimestamp: 1_000,
                logID: "first"
            ),
            ConversationStore.HistoryPrefetchTarget(
                remote: secondRemote,
                channelID: "second",
                reason: "recent_activity",
                latestSeq: 20,
                sortTimestamp: 900,
                logID: "second"
            ),
            ConversationStore.HistoryPrefetchTarget(
                remote: thirdRemote,
                channelID: "third",
                reason: "latest_seq",
                latestSeq: 60,
                sortTimestamp: 800,
                logID: "third"
            )
        ]

        let plan = store.historyPrefetchExecutionPlan(
            targets: targets,
            messageLimit: 50,
            maxConcurrent: 2
        )

        XCTAssertEqual(plan.maxConcurrent, 2)
        XCTAssertEqual(plan.commands.map(\.channelID), ["first", "second", "third"])
        XCTAssertEqual(plan.commands.map(\.apiChannelID), ["first", "second", "third"])
        XCTAssertEqual(plan.commands.map(\.afterSeq), [70, 0, 10])
        XCTAssertEqual(plan.commands.map(\.limit), [50, 50, 50])
        XCTAssertEqual(plan.commands.map(\.reason), ["unread", "recent_activity", "latest_seq"])
        XCTAssertEqual(
            plan.targetSummary,
            "first#seq120#ts1000#unread,second#seq20#ts900#recent_activity,third#seq60#ts800#latest_seq"
        )
        XCTAssertEqual(
            plan.batches.map { $0.map(\.channelID) },
            [["first", "second"], ["third"]]
        )

        let serialPlan = store.historyPrefetchExecutionPlan(
            targets: Array(targets.prefix(2)),
            messageLimit: 50,
            maxConcurrent: 0
        )
        XCTAssertEqual(serialPlan.maxConcurrent, 1)
        XCTAssertEqual(serialPlan.batches.map { $0.map(\.channelID) }, [["first"], ["second"]])
    }

    func testConversationStoreHistoryPrefetchReadReceiptBackfillPreservesDeliveryAcrossDetailedReceiptConfig() throws {
        let store = ConversationStore()
        var outgoingConversation = makeConversation(id: "outgoing", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        outgoingConversation.messages = [
            makeMessage(id: "out-1", seq: 1, isOutgoing: true)
        ]
        var incomingOnlyConversation = makeConversation(id: "incoming", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        incomingOnlyConversation.messages = [
            makeMessage(id: "in-1", seq: 1)
        ]
        store.conversations = [outgoingConversation, incomingOnlyConversation]

        let outgoingRemote = try decodeRemoteConversation("""
        {"channel_id":"outgoing","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let incomingRemote = try decodeRemoteConversation("""
        {"channel_id":"incoming","channel_type":"group","last_msg_seq":3,"unread_count":0}
        """)
        let plan = store.historyPrefetchExecutionPlan(
            targets: [
                ConversationStore.HistoryPrefetchTarget(
                    remote: outgoingRemote,
                    channelID: "outgoing",
                    reason: "recent_activity",
                    latestSeq: 3,
                    sortTimestamp: 300,
                    logID: "outgoing"
                ),
                ConversationStore.HistoryPrefetchTarget(
                    remote: incomingRemote,
                    channelID: "incoming",
                    reason: "recent_activity",
                    latestSeq: 3,
                    sortTimestamp: 200,
                    logID: "incoming"
                )
            ],
            messageLimit: 50,
            maxConcurrent: 2
        )

        let outgoingCommand = try XCTUnwrap(plan.commands.first { $0.channelID == "outgoing" })
        let incomingCommand = try XCTUnwrap(plan.commands.first { $0.channelID == "incoming" })

        XCTAssertEqual(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: outgoingCommand,
                readReceiptsEnabled: true,
                channelIDForConversation: { $0.id }
            ),
            ConversationStore.HistoryPrefetchReadReceiptBackfillTarget(
                channelID: "outgoing",
                channelType: "group"
            )
        )
        XCTAssertEqual(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: outgoingCommand,
                readReceiptsEnabled: false,
                channelIDForConversation: { $0.id }
            ),
            ConversationStore.HistoryPrefetchReadReceiptBackfillTarget(
                channelID: "outgoing",
                channelType: "group"
            )
        )
        XCTAssertNil(
            store.historyPrefetchReadReceiptBackfillTarget(
                for: incomingCommand,
                readReceiptsEnabled: true,
                channelIDForConversation: { $0.id }
            )
        )
    }

    func testConversationStoreOlderHistoryFilterRejectsCurrentAndDuplicateMessages() throws {
        let store = ConversationStore()
        let older = try decodeRemoteMessage("""
        {
          "message_id": "m1",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 1,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let current = try decodeRemoteMessage("""
        {
          "message_id": "m3",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 3,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let unsequenced = try decodeRemoteMessage("""
        {
          "message_id": "m0",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 0,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)

        XCTAssertTrue(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(current, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(unsequenced, oldestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: ["m1"], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageOlderThanCurrentWindow(older, oldestSeq: 3, existingIDs: [], existingSeqs: [1]))
    }

    func testConversationStoreNewerHistoryFilterRejectsCurrentAndDuplicateMessages() throws {
        let store = ConversationStore()
        let newer = try decodeRemoteMessage("""
        {
          "message_id": "m5",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 5,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let current = try decodeRemoteMessage("""
        {
          "message_id": "m3",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 3,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)
        let unsequenced = try decodeRemoteMessage("""
        {
          "message_id": "m0",
          "channel_id": "c1",
          "channel_type": "group",
          "channel_seq": 0,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """)

        XCTAssertTrue(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(current, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(unsequenced, newestSeq: 3, existingIDs: [], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: ["m5"], existingSeqs: []))
        XCTAssertFalse(store.isRemoteMessageNewerThanCurrentWindow(newer, newestSeq: 3, existingIDs: [], existingSeqs: [5]))
    }

    func testRealtimeMessageIngestBufferGroupsByScopeAndConversationOrder() throws {
        var buffer = RealtimeMessageIngestBuffer()
        let first = try decodeRemoteMessage(remoteMessageJSON(id: "m1", channelID: "g1", channelType: "group", seq: 1))
        let second = try decodeRemoteMessage(remoteMessageJSON(id: "m2", channelID: "g1", channelType: "group", seq: 2))
        let third = try decodeRemoteMessage(remoteMessageJSON(id: "m3", channelID: "g2", channelType: "group", seq: 1))
        let stale = try decodeRemoteMessage(remoteMessageJSON(id: "stale", channelID: "g1", channelType: "group", seq: 3))

        buffer.append(first, scopeKey: "scope-a")
        buffer.append(third, scopeKey: "scope-a")
        buffer.append(stale, scopeKey: "scope-b")
        buffer.append(second, scopeKey: "scope-a")

        let groups = buffer.drainGrouped(currentScopeKey: "scope-a")

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].channelID, "g1")
        XCTAssertEqual(groups[0].messages.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(groups[1].channelID, "g2")
        XCTAssertEqual(groups[1].messages.map(\.messageID), ["m3"])
    }

    func testConversationScrollArbiterNormalJumpAndGenerationRules() {
        var arbiter = ConversationScrollArbiter()
        let now = Date(timeIntervalSince1970: 100)
        arbiter.beginNormalOpen(now: now, duration: 3)
        let generation = arbiter.generation

        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1)
            ),
            .allow
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .readAck, targetID: "m1", anchor: .center, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1)
            ),
            .deny
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .searchJump, targetID: "old", anchor: .center, userInitiated: true, generation: generation),
                now: now.addingTimeInterval(1.2)
            ),
            .allowAndEndWindow
        )
        XCTAssertTrue(arbiter.isJumpMode)
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(1.4)
            ),
            .deny
        )
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .jumpToLatest, targetID: "bottom", anchor: .bottom, userInitiated: true, generation: generation),
                now: now.addingTimeInterval(1.6)
            ),
            .allowAndEndWindow
        )
        XCTAssertFalse(arbiter.isJumpMode)

        arbiter.beginNormalOpen(now: now.addingTimeInterval(10), duration: 3)
        XCTAssertEqual(
            arbiter.evaluate(
                ConversationScrollRequest(source: .followBottom, targetID: "bottom", anchor: .bottom, userInitiated: false, generation: generation),
                now: now.addingTimeInterval(11)
            ),
            .deny
        )
    }

    func testConversationStoreHistoryBoundaryFiltersRestrictedGroupMessagesFailClosed() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "g1", kind: .group, unread: 3, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m420", seq: 420),
            makeMessage(id: "m0", seq: 0),
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]

        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 421, limited: true),
            to: conversation,
            keepPendingLocalMessages: false
        ))

        XCTAssertEqual(bounded.messages.map(\.id), ["m421", "m422"])
        XCTAssertEqual(bounded.lastMessage, "m422")
        XCTAssertEqual(bounded.unread, 0)
        XCTAssertEqual(bounded.historyVisibleFromSeq, 421)
        XCTAssertTrue(bounded.historyLimited)
        XCTAssertTrue(bounded.historyBoundaryConfirmed)
    }

    func testConversationStoreHistoryBoundaryDecreaseClearsOldSnapshotForNewEpisode() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "g1", kind: .group, unread: 0, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true
        conversation.messages = [
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"

        let widened = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 1, limited: false),
            to: conversation
        ))

        XCTAssertTrue(widened.messages.isEmpty)
        XCTAssertEqual(widened.lastMessage, "")
        XCTAssertEqual(widened.historyVisibleFromSeq, 1)
        XCTAssertFalse(widened.historyLimited)
        XCTAssertTrue(widened.historyBoundaryConfirmed)
    }

    func testConversationStoreHistoryBoundaryDoesNotClipDirectConversation() throws {
        let store = ConversationStore()
        var conversation = makeConversation(id: "d1", kind: .direct, unread: 1, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1),
            makeMessage(id: "m420", seq: 420)
        ]

        let bounded = try XCTUnwrap(store.applyingHistoryVisibilityBoundary(
            ConversationStore.HistoryVisibilityBoundary(fromSeq: 421, limited: true),
            to: conversation
        ))

        XCTAssertEqual(bounded.messages.map(\.id), ["m1", "m420"])
        XCTAssertFalse(bounded.historyBoundaryConfirmed)
    }

    func testConfirmedCachedGroupConversationPublishesItsBoundaryAdmittedHistoryImmediately() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "g1", kind: .group, unread: 4, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m420", seq: 420),
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = true

        let safe = store.conversationPreparedForLocalHistoryProjection(conversation)

        XCTAssertEqual(safe.messages.map(\.id), ["m421", "m422"])
        XCTAssertEqual(safe.lastMessage, "m422")
        XCTAssertEqual(safe.unread, 0)
        XCTAssertTrue(safe.historyBoundaryConfirmed)
    }

    func testUnconfirmedCachedGroupConversationStillFailsClosedBeforeLocalProjection() {
        let store = ConversationStore()
        var conversation = makeConversation(id: "g1", kind: .group, unread: 4, lastMsgSeq: 422, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m421", seq: 421),
            makeMessage(id: "m422", seq: 422)
        ]
        conversation.lastMessage = "m422"
        conversation.historyVisibleFromSeq = 421
        conversation.historyLimited = true
        conversation.historyBoundaryConfirmed = false

        let safe = store.conversationPreparedForLocalHistoryProjection(conversation)

        XCTAssertTrue(safe.messages.isEmpty)
        XCTAssertEqual(safe.lastMessage, "")
        XCTAssertEqual(safe.unread, 0)
        XCTAssertFalse(safe.historyBoundaryConfirmed)
    }

    func testConversationSelectionEpochFenceRejectsLateAtoBtoAResponses() {
        var fence = ConversationSelectionEpochFence()

        let firstA = fence.select(scope: "scope-one", conversationID: "direct-a")
        let selectedB = fence.select(scope: "scope-one", conversationID: "direct-b")
        let secondA = fence.select(scope: "scope-one", conversationID: "direct-a")

        XCTAssertFalse(fence.accepts(firstA))
        XCTAssertFalse(fence.accepts(selectedB))
        XCTAssertTrue(fence.accepts(secondA))

        fence.leave(scope: "scope-one", conversationID: "direct-a")
        XCTAssertFalse(fence.accepts(secondA))
    }

    func testGroupHistoryBoundaryGenerationTrackerDropsOutOfOrderResponses() {
        var tracker = GroupHistoryBoundaryGenerationTracker()
        let first = tracker.begin(key: "tenant|user|g1")
        let second = tracker.begin(key: "tenant|user|g1")

        XCTAssertFalse(tracker.accepts(key: "tenant|user|g1", generation: first))
        XCTAssertTrue(tracker.accepts(key: "tenant|user|g1", generation: second))
        XCTAssertTrue(tracker.accepts(key: "tenant|user|g2", generation: nil))
    }

    @MainActor
    func testRemovingFriendRelationshipPreservesReadableDirectHistoryAndParticipantSnapshot() {
        let peer = makeUser(id: "peer-retained", name: "Retained Peer")
        var conversation = makeConversation(
            id: "direct-retained",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.participants = [peer]
        conversation.messages = [makeMessage(id: "history-1", senderId: peer.id, seq: 1)]
        let store = ConversationStore()
        store.conversations = [conversation]
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let state = AppState(
            conversationStore: store,
            messageStore: SnapshotCache(directoryURL: cacheDirectory)
        )
        state.contacts = [peer]
        state.contactRemarks = [peer.id: "旧备注"]

        state.removeFriendData(peer)

        XCTAssertFalse(state.contacts.contains { $0.id == peer.id })
        XCTAssertNil(state.contactRemarks[peer.id])
        XCTAssertEqual(state.conversations.first?.messages.map(\.id), ["history-1"])
        XCTAssertEqual(state.conversations.first?.participants.map(\.id), [peer.id])
    }

    @MainActor
    func testBlockingFriendPreservesPrivateRemarkAndReadableDirectHistory() {
        let peer = makeUser(id: "peer-blocked", name: "Blocked Peer")
        var conversation = makeConversation(
            id: "direct-blocked",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.participants = [peer]
        conversation.messages = [makeMessage(id: "blocked-history-1", senderId: peer.id, seq: 1)]
        let store = ConversationStore()
        store.conversations = [conversation]
        let state = AppState(conversationStore: store)
        state.contacts = [peer]
        state.contactRemarks = [peer.id: "查看者私有备注"]

        state.removeFriendData(peer, removePrivateRemark: false)

        XCTAssertFalse(state.contacts.contains { $0.id == peer.id })
        XCTAssertEqual(state.contactRemarks[peer.id], "查看者私有备注")
        XCTAssertEqual(state.conversations.first?.messages.map(\.id), ["blocked-history-1"])
        XCTAssertEqual(state.conversations.first?.participants.map(\.id), [peer.id])
    }

    @MainActor
    func testBackgroundSystemNotificationNeverUsesViewerPrivateRemark() {
        let privateRemark = "查看者私有备注"
        let peer = makeUser(id: "peer-notification", name: privateRemark)
        var conversation = makeConversation(
            id: "self:peer-notification",
            kind: .direct,
            unread: 1,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.title = privateRemark
        conversation.participants = [peer]
        let state = AppState()
        state.contacts = [peer]
        state.contactRemarks = [peer.id: privateRemark]
        var privateSnapshot = makeMessage(id: "message-private", senderId: peer.id, seq: 1)
        privateSnapshot.senderName = privateRemark

        XCTAssertEqual(
            state.systemNotificationTitleForTesting(
                conversation: conversation,
                latestIncomingMessage: privateSnapshot
            ),
            "问达通"
        )

        var publicSnapshot = privateSnapshot
        publicSnapshot.senderName = "Public Nickname"
        XCTAssertEqual(
            state.systemNotificationTitleForTesting(
                conversation: conversation,
                latestIncomingMessage: publicSnapshot
            ),
            "问达通"
        )

        let privateContactCard = makeMessage(
            id: "private-contact-card",
            senderId: peer.id,
            seq: 2,
            text: privateRemark,
            kind: .contactCard
        )
        let privateSystemMessage = makeMessage(
            id: "private-system-message",
            senderId: peer.id,
            seq: 3,
            text: privateRemark,
            kind: .system
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(message: privateContactCard),
            "收到新消息通知"
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(message: privateSystemMessage),
            "收到新消息通知"
        )
        XCTAssertEqual(
            state.systemNotificationBodyForTesting(
                message: makeMessage(id: "ordinary-text", seq: 4, text: "公开消息")
            ),
            "收到新消息通知"
        )
    }

    func testBiometricProtectionRequiresAuthenticationBeforePersistingAndRestoresByAccountScope() async throws {
        let defaultsName = "BlueStoneIMTests.biometric.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let context = makeAuthenticatedAPIContext()
        let rejectedAuthenticator = RecordingBiometricAuthenticator(
            error: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)
        )
        let rejectedState = AppState(
            biometricAuthenticator: rejectedAuthenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )
        var rejectedDraft = BiometricProtectionSettingsDraft(settings: rejectedState.biometricProtectionSettings)
        let rejectedRequest = try XCTUnwrap(rejectedDraft.beginEnabledChange(to: true))
        XCTAssertFalse(rejectedDraft.enabled)
        let rejectedSave = await rejectedState.saveBiometricProtectionSettings(
            enabled: rejectedRequest.enabled,
            unlockChats: rejectedRequest.unlockChats,
            previewFiles: rejectedRequest.previewFiles
        )
        rejectedDraft.finish(with: rejectedState.biometricProtectionSettings)
        XCTAssertFalse(rejectedSave)
        XCTAssertFalse(rejectedDraft.enabled)
        XCTAssertFalse(rejectedDraft.isUpdating)
        XCTAssertFalse(rejectedState.biometricProtectionSettings.enabled)
        XCTAssertEqual(rejectedAuthenticator.requestCount, 1)
        XCTAssertEqual(rejectedState.toast, "Face ID 验证已取消")
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: context)))

        let authenticator = RecordingBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )

        XCTAssertFalse(state.biometricProtectionSettings.enabled)
        var enableDraft = BiometricProtectionSettingsDraft(settings: state.biometricProtectionSettings)
        let requestedEnable = try XCTUnwrap(enableDraft.beginEnabledChange(to: true))
        XCTAssertFalse(enableDraft.enabled, "Enable-time verification must not optimistically flip the UI")
        XCTAssertTrue(enableDraft.isUpdating)
        let didSave = await state.saveBiometricProtectionSettings(
            enabled: requestedEnable.enabled,
            unlockChats: requestedEnable.unlockChats,
            previewFiles: false
        )
        enableDraft.finish(with: state.biometricProtectionSettings)
        XCTAssertTrue(didSave)
        XCTAssertEqual(authenticator.requestCount, 1)
        XCTAssertTrue(enableDraft.enabled)
        XCTAssertTrue(state.requiresChatBiometricProtection)
        XCTAssertFalse(state.requiresFileBiometricProtection)
        let unprotectedFileWasAuthorized = await state.authorizeProtectedAccess(.filePreview)
        XCTAssertTrue(unprotectedFileWasAuthorized)
        XCTAssertEqual(authenticator.requestCount, 1)

        let restored = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context
        )
        XCTAssertEqual(restored.biometricProtectionSettings, state.biometricProtectionSettings)
        let didAuthorize = await restored.authorizeProtectedAccess(.chat)
        XCTAssertTrue(didAuthorize)
        XCTAssertEqual(authenticator.requestCount, 2)

        let otherAccount = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        )
        XCTAssertEqual(otherAccount.biometricProtectionSettings, .disabled)

        var emptyAccountContext = makeAuthenticatedAPIContext(accountID: "", imUID: "uid-fallback")
        emptyAccountContext.accountID = ""
        XCTAssertTrue(
            BiometricProtectionStore.scopeKey(context: emptyAccountContext).hasSuffix(".uid-fallback")
        )
    }

    func testBiometricEnableDoesNotWriteAcrossAccountSwitchDuringAuthentication() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-enable-scope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let firstContext = makeAuthenticatedAPIContext()
        let secondContext = makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        let authenticator = SuspendedBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: firstContext
        )

        let save = Task {
            await state.saveBiometricProtectionSettings(
                enabled: true,
                unlockChats: true,
                previewFiles: true
            )
        }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)
        state.overrideAPIContextForTesting(secondContext)
        authenticator.succeed()

        let didSave = await save.value
        XCTAssertFalse(didSave)
        XCTAssertEqual(state.toast, "登录状态已变化，请重新设置 Face ID")
        XCTAssertEqual(state.biometricProtectionSettings, .disabled)
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: firstContext)))
        XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: secondContext)))
    }

    func testBiometricProtectionAllowsSuccessfulSystemPromptAfterSceneBecomesInactiveAndRelocksLater() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-prompt-inactive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let context = makeAuthenticatedAPIContext()
        try BiometricProtectionStore.save(
            BiometricProtectionSettings(enabled: true, unlockChats: true, previewFiles: true),
            context: context,
            defaults: defaults
        )
        let authenticator = SuspendedBiometricAuthenticator()
        let riskTelemetry = IOSRiskTelemetryController(
            queueStore: IOSRiskTelemetryQueueStore(
                defaults: defaults,
                keyPrefix: "biometric-prompt-risk"
            ),
            submit: { _, events in
                IOSRiskActivityBatchResult(items: events.indices.map {
                    IOSRiskActivityItemResult(index: $0, status: "accepted")
                })
            }
        )
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: context,
            iosRiskTelemetry: riskTelemetry
        )
        let accessScopeBeforePrompt = state.biometricAccessScopeToken
        XCTAssertFalse(state.isProtectedAccessAuthorized(.chat))
        let authorization = Task { await state.authorizeProtectedAccess(.chat) }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)

        // Presenting the system Face ID sheet makes the app scene inactive. That lifecycle
        // transition must relock any prior grant without invalidating this in-flight prompt.
        state.appDidBecomeInactive()
        XCTAssertNotEqual(state.biometricAccessScopeToken, accessScopeBeforePrompt)
        authenticator.succeed()

        let wasAuthorized = await authorization.value
        XCTAssertTrue(wasAuthorized)
        XCTAssertTrue(state.isProtectedAccessAuthorized(.chat))

        let accessScopeAfterPrompt = state.biometricAccessScopeToken
        state.appDidEnterBackground()
        XCTAssertNotEqual(state.biometricAccessScopeToken, accessScopeAfterPrompt)
        XCTAssertFalse(state.isProtectedAccessAuthorized(.chat))
    }

    func testBiometricProtectionRejectsStaleAuthenticationAndRelocksProtectedSurfaces() async throws {
        let defaultsName = "BlueStoneIMTests.biometric-stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let firstContext = makeAuthenticatedAPIContext()
        try BiometricProtectionStore.save(
            BiometricProtectionSettings(enabled: true, unlockChats: true, previewFiles: true),
            context: firstContext,
            defaults: defaults
        )
        let authenticator = SuspendedBiometricAuthenticator()
        let state = AppState(
            biometricAuthenticator: authenticator,
            biometricDefaults: defaults,
            apiContextOverride: firstContext
        )
        let initialScopeToken = state.biometricAccessScopeToken
        let authorization = Task { await state.authorizeProtectedAccess(.chat) }
        for _ in 0..<1_000 where !authenticator.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(authenticator.isWaiting)

        state.overrideAPIContextForTesting(
            makeAuthenticatedAPIContext(accountID: "account-2", imUID: "uid-2")
        )
        authenticator.succeed()

        let wasAuthorized = await authorization.value
        XCTAssertFalse(wasAuthorized)
        XCTAssertEqual(state.toast, "登录状态已变化，请重新验证")
        XCTAssertNotEqual(state.biometricAccessScopeToken, initialScopeToken)
        XCTAssertEqual(state.biometricProtectionSettings, .disabled)

        let beforeInactive = state.biometricAccessScopeToken
        state.appDidBecomeInactive()
        XCTAssertNotEqual(state.biometricAccessScopeToken, beforeInactive)
    }

    func testBiometricEnableErrorsRemainTruthfulAndNeverPersist() async throws {
        let cases: [(LAError.Code, String)] = [
            (.biometryNotAvailable, "此设备不支持 Face ID"),
            (.biometryNotEnrolled, "请先在系统设置中录入 Face ID"),
            (.biometryLockout, "Face ID 已锁定，请先在系统设置中解锁"),
            (.authenticationFailed, "Face ID 验证失败，请重试")
        ]
        for (code, message) in cases {
            let defaultsName = "BlueStoneIMTests.biometric-error.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let context = makeAuthenticatedAPIContext()
            let state = AppState(
                biometricAuthenticator: RecordingBiometricAuthenticator(error: LAError(code)),
                biometricDefaults: defaults,
                apiContextOverride: context
            )

            let didSave = await state.saveBiometricProtectionSettings(
                enabled: true,
                unlockChats: true,
                previewFiles: true
            )
            XCTAssertFalse(didSave)
            XCTAssertEqual(state.biometricProtectionSettings, .disabled)
            XCTAssertEqual(state.toast, message)
            XCTAssertNil(defaults.data(forKey: BiometricProtectionStore.scopeKey(context: context)))
        }
    }

    func testAppCacheCleanerDeletesOnlyOwnedRootsAndReportsRealBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-cache-\(UUID().uuidString)", isDirectory: true)
        let cacheBase = root.appendingPathComponent("Caches", isDirectory: true)
        let tempBase = root.appendingPathComponent("Temp", isDirectory: true)
        let ownedCache = cacheBase.appendingPathComponent("BlueStoneIMAttachmentDownloads", isDirectory: true)
        let ownedTemp = tempBase.appendingPathComponent("BlueStoneIMFilePreviews", isDirectory: true)
        let unrelated = cacheBase.appendingPathComponent("UserOwned", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [ownedCache, ownedTemp, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(repeating: 7, count: 4_096).write(to: ownedCache.appendingPathComponent("a.bin"))
        try Data(repeating: 8, count: 2_048).write(to: ownedTemp.appendingPathComponent("b.bin"))
        try Data(repeating: 9, count: 128).write(to: unrelated.appendingPathComponent("keep.bin"))

        let result = await AppCacheCleaner.clear(cacheBase: cacheBase, temporaryBase: tempBase)

        XCTAssertGreaterThanOrEqual(result.bytesRemoved, 6_144)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.bin").path))
    }

    func testProjectedGroupDirectoryRetainsAuthoritativeGroupsAndAddsConversationBackedMemberships() {
        let authoritative = GroupInfo(
            id: "group-authoritative",
            name: "权威群",
            notice: "公告",
            owner: "群主",
            members: [],
            admins: [],
            muted: false,
            allMuted: false,
            myRole: "owner"
        )
        var matchingConversation = makeConversation(
            id: authoritative.id,
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        matchingConversation.title = authoritative.name

        let member = makeUser(id: "member-1", name: "群成员")
        var conversationBacked = makeConversation(
            id: "group-conversation-backed",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversationBacked.title = "会话已验证群"
        conversationBacked.participants = [member]
        conversationBacked.memberCount = 7
        conversationBacked.isMuted = true
        conversationBacked.avatarURL = "https://example.invalid/group.png"

        let projected = ContactStore.projectedGroupDirectory(
            authoritativeGroups: [authoritative],
            conversations: [matchingConversation, conversationBacked]
        )

        XCTAssertEqual(projected.map(\.id), [authoritative.id, conversationBacked.id])
        XCTAssertEqual(projected[0], authoritative)
        XCTAssertEqual(projected[1].name, conversationBacked.title)
        XCTAssertEqual(projected[1].myRole, "member")
        XCTAssertEqual(projected[1].members, [member])
        XCTAssertEqual(projected[1].memberCount, 7)
        XCTAssertTrue(projected[1].membersPartial)
        XCTAssertTrue(projected[1].muted)
        XCTAssertEqual(projected[1].avatarURL, conversationBacked.avatarURL)
        XCTAssertFalse(projected[1].canCurrentUserManage)
    }

    func testProjectedGroupDirectoryDeduplicatesAConversationWithAnAuthoritativeGroupName() {
        let authoritative = GroupInfo(
            id: "remote-group-id",
            name: "同名群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false
        )
        var conversation = makeConversation(
            id: "local-conversation-id",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        conversation.title = " 同名群 "

        let projected = ContactStore.projectedGroupDirectory(
            authoritativeGroups: [authoritative],
            conversations: [conversation]
        )

        XCTAssertEqual(projected, [authoritative])
    }

    func testGroupFilePreviewPolicyKeepsPreviewableFilesInsideTheApp() {
        var previewable = FileItem(
            id: "file-1",
            name: "image.png",
            type: "PNG",
            size: "1 KB",
            owner: "Member",
            source: "Group",
            time: "10:00",
            scope: "群文件",
            status: "可预览",
            accentHex: 0x5D6BFF
        )
        previewable.previewAvailable = true
        var unavailable = previewable
        unavailable.previewAvailable = false

        XCTAssertEqual(GroupFilePreviewPolicy.inAppDestination(for: previewable), previewable)
        XCTAssertNil(GroupFilePreviewPolicy.inAppDestination(for: unavailable))
    }

    private func makeConversation(
        id: String,
        kind: ConversationKind = .direct,
        unread: Int,
        lastMsgSeq: Int64,
        lastReadSeq: Int64
    ) -> Conversation {
        Conversation(
            id: id,
            title: id,
            subtitle: "",
            kind: kind,
            lastMessage: "",
            time: "",
            unread: unread,
            isPinned: false,
            isMuted: false,
            memberCount: 0,
            accentHex: 0,
            participants: [],
            messages: [],
            hasUnreadReaction: true,
            unreadReactionCount: 2,
            lastMsgSeq: lastMsgSeq,
            lastReadSeq: lastReadSeq,
            firstUnreadSeq: 3,
            firstUnreadMessageID: "m3",
            unreadAnchorSeq: 3,
            unreadAnchorState: "unread"
        )
    }

    private func makeMessage(
        id: String,
        senderId: String = "u1",
        seq: Int64,
        status: MessageDelivery = .sent,
        isOutgoing: Bool = false,
        isPinned: Bool = false,
        isDeletedLocally: Bool = false,
        text: String? = nil,
        time: String = "",
        kind: MessageKind = .text
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id,
            senderId: senderId,
            senderName: "User",
            text: text ?? id,
            time: time,
            channelSeq: seq,
            isOutgoing: isOutgoing,
            status: status,
            kind: kind,
            reactions: [],
            readBy: [],
            unreadBy: [],
            isPinned: isPinned
        )
        message.isDeletedLocally = isDeletedLocally
        return message
    }

    private func makeGroupInviteApproval(
        requestID: String,
        status: String = "pending",
        resultText: String = "",
        processed: Bool = false,
        approverName: String = "",
        approverAccountID: String = "",
        decidedAt: String = "",
        canApprove: Bool = true,
        canReject: Bool = true
    ) -> GroupInviteApproval {
        GroupInviteApproval(
            requestID: requestID,
            requestType: "invite",
            groupID: "group-1",
            groupName: "群聊",
            inviterName: "邀请人",
            inviterAccountID: "inviter-1",
            inviteeName: "被邀请人",
            inviteeAccountID: "invitee-1",
            status: status,
            resultText: resultText,
            processed: processed,
            approverName: approverName,
            approverAccountID: approverAccountID,
            decidedAt: decidedAt,
            canApprove: canApprove,
            canReject: canReject,
            approveEndpoint: "/approve",
            rejectEndpoint: "/reject",
            actionEndpoint: "/review",
            kind: "group_invite_approval"
        )
    }

    private func decodeRemoteReceipt(_ json: String) throws -> RemoteMessageReceipt {
        try JSONDecoder().decode(RemoteMessageReceipt.self, from: Data(json.utf8))
    }

    private func remoteMessageJSON(id: String, channelID: String, channelType: String, seq: Int64) -> String {
        """
        {
          "message_id": "\(id)",
          "channel_id": "\(channelID)",
          "channel_type": "\(channelType)",
          "channel_seq": \(seq),
          "from_uid": "u1",
          "content_type": "text",
          "payload": {},
          "status": "normal"
        }
        """
    }

    private func decodeRemoteMessage(_ json: String) throws -> RemoteMessage {
        try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))
    }

    private func decodeRemoteConversation(_ json: String) throws -> RemoteConversation {
        try JSONDecoder().decode(RemoteConversation.self, from: Data(json.utf8))
    }

    private func decodeRemoteExtra(_ json: String) throws -> RemoteMessageExtra {
        try JSONDecoder().decode(RemoteMessageExtra.self, from: Data(json.utf8))
    }

    private func decodeRemoteReadReceiptResponse(_ json: String) throws -> RemoteMessageReadReceiptResponse {
        try JSONDecoder().decode(RemoteMessageReadReceiptResponse.self, from: Data(json.utf8))
    }

    private func makeReadReceipt(from receipt: RemoteMessageReceipt, conversation _: Conversation) -> ReadReceipt {
        ReadReceipt(
            id: "\(receipt.imUID)_\(receipt.deviceID)_\(receipt.channelSeq)",
            user: makeUser(id: receipt.imUID, name: receipt.displayName.isEmpty ? receipt.imUID : receipt.displayName),
            device: receipt.deviceID.isEmpty ? "设备未同步" : receipt.deviceID,
            time: receipt.createdAt ?? ""
        )
    }

    private func makeReadReceipt(userID: String) -> ReadReceipt {
        ReadReceipt(
            id: userID,
            user: makeUser(id: userID),
            device: "ios",
            time: "10:00"
        )
    }

    private func makeUnreadReadReceipt(from participant: RemoteMessageReadParticipant, conversation _: Conversation) -> ReadReceipt {
        ReadReceipt(
            id: "unread_\(participant.imUID)",
            user: makeUser(id: participant.imUID, name: participant.displayName.isEmpty ? participant.imUID : participant.displayName),
            device: participant.deviceID.isEmpty ? "未同步" : participant.deviceID,
            time: participant.readAt ?? "未读"
        )
    }

    private func makeReactionDetail(from receipt: RemoteMessageReactionReceipt) -> ReactionDetail {
        ReactionDetail(
            id: "\(receipt.messageID)_\(receipt.operatorUID)_\(receipt.emoji)",
            emoji: receipt.emoji,
            user: makeUser(id: receipt.operatorUID, name: receipt.operatorName.isEmpty ? receipt.operatorUID : receipt.operatorName),
            time: receipt.createdAt ?? ""
        )
    }

    private func makeReactionDetail(from extra: RemoteMessageExtra, id: String) -> ReactionDetail {
        ReactionDetail(
            id: id,
            emoji: extra.emoji,
            user: makeUser(id: extra.operatorUID, name: extra.operatorName.isEmpty ? extra.operatorUID : extra.operatorName),
            time: extra.createdAt ?? ""
        )
    }

    private func makeUser(
        id: String,
        name: String? = nil,
        userID: String = "",
        username: String = "",
        status: String = "在线",
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = ""
    ) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name ?? id,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: status,
            enterprise: "",
            avatarSeed: 0,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: []
        )
    }

    private func makeIsolatedAPIContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
    }

    private func videoCallRuntimeRouteSnapshot() throws -> IMRuntimeRouteSnapshot {
        let services: [String: IMRuntimeRouteEndpointSet] = [
            IMRuntimeRouteService.platformAPI.rawValue: .init(
                preferred: ["https://platform-primary.example.test"],
                backups: ["https://platform-backup.example.test"],
                preferredSource: "app_preferred",
                backupSource: "common_platform_backup"
            ),
            IMRuntimeRouteService.tenantAPI.rawValue: .init(
                preferred: ["https://tenant-primary.example.test"],
                backups: ["https://tenant-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            ),
            IMRuntimeRouteService.imAPI.rawValue: .init(
                preferred: ["https://im-primary.example.test"],
                backups: ["https://im-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            ),
            IMRuntimeRouteService.imRealtime.rawValue: .init(
                preferred: ["wss://realtime-primary.example.test"],
                backups: ["wss://realtime-backup.example.test"],
                preferredSource: "tenant_deployment_authority",
                backupSource: "tenant_deployment_backup"
            )
        ]
        let unsigned = IMRuntimeRouteSnapshot(
            contractVersion: 2,
            appID: IMAPIContext.canonicalIOSAppID,
            tenantID: "tenant-1",
            revision: 1,
            source: "tenant_entry",
            status: "ready",
            configHash: String(repeating: "0", count: 64),
            services: services,
            policy: IMRuntimeRoutePolicy()
        )
        return IMRuntimeRouteSnapshot(
            contractVersion: unsigned.contractVersion,
            appID: unsigned.appID,
            tenantID: unsigned.tenantID,
            revision: unsigned.revision,
            source: unsigned.source,
            status: unsigned.status,
            configHash: try XCTUnwrap(unsigned.recomputedConfigHash),
            services: services,
            policy: unsigned.policy
        )
    }

    private func makeAuthenticatedAPIContext(
        accountID: String = "account-1",
        imUID: String = "uid-1"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: accountID,
            tenantID: "tenant-1",
            imUID: imUID,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
    }

    private func successfulEmptyAPIResponse() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    private func makeCallEndingAPI(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            httpTransport: transport
        )
    }

    private func makeRTCMediaHeartbeatState(
        transport: HTTPTransport,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> AppState {
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            rtcMediaHeartbeatIntervalNanoseconds: 3_600_000_000_000,
            rtcMediaHeartbeatNow: now,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.isAuthenticated = true
        return state
    }

    private func makeRTCMediaHeartbeatVideoCall(callID: String) -> VoiceCallSession {
        VoiceCallSession(
            id: "local-\(callID)",
            callID: callID,
            roomID: "room-\(callID)",
            rtcToken: "rtc-token-\(callID)",
            peer: makeUser(id: "peer-\(callID)", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            stateVersion: 1
        )
    }

    private func rtcMediaHeartbeatJoinedRoom(token: String) -> RemoteRTCRoomJoinData {
        RemoteRTCRoomJoinData(
            roomID: "room-heartbeat",
            rtcToken: token,
            selfParticipant: RemoteRTCRoomParticipant(
                uid: "uid-1",
                deviceID: "ios-device-1",
                deviceType: "ios",
                role: "self"
            ),
            participants: []
        )
    }

    private func rtcMediaHeartbeatCallResult(callID: String, stateVersion: Int64) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(
                """
                {"ok":true,"data":{"call":{
                  "id":"\(callID)",
                  "status":"accepted",
                  "state_version":\(stateVersion)
                }}}
                """.utf8
            ),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    private func rtcMediaHeartbeatErrorResult(statusCode: Int, code: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(
                #"{"ok":false,"error":{"code":"\#(code)","message":"rtc heartbeat failed"}}"#.utf8
            ),
            isHTTPResponse: true,
            statusCode: statusCode
        )
    }

    private func waitForRTCMediaHeartbeatRequests(
        _ count: Int,
        transport: RTCMediaHeartbeatHTTPTransport
    ) async {
        for _ in 0..<200 {
            if transport.requests().count >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForCallEnd(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForRequestCount(
        _ count: Int,
        path: String,
        transport: RTCDeviceCapabilityBootstrapHTTPTransport
    ) async {
        for _ in 0..<100 {
            if transport.requestCount(path: path) >= count {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func videoCallEnabledFileConfig() -> FileUploadConfig {
        callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
    }

    private func callLicenseFileConfig(
        voiceEnabled: Bool,
        videoEnabled: Bool
    ) -> FileUploadConfig {
        FileUploadConfig(
            maxBytes: 20 * 1024 * 1024,
            maxMB: 20,
            source: "test",
            messageRecallMaxMinutes: 120,
            voiceCallEnabled: voiceEnabled,
            videoCallEnabled: videoEnabled,
            readReceiptsEnabled: true,
            groupAdminDeleteMessageEnabled: false
        )
    }

    private func makeSearchJumpAPI(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
    }
}

private final class BatchForwardLifecycleHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Behavior {
        case waitForCancellation
        case returnCommittedAfterCancellation
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var startedForwardRequest = false
    private var observedCancellation = false
    private var returnedForwardResponse = false

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var didStartForwardRequest: Bool {
        lock.withLock { startedForwardRequest }
    }

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    var didReturnForwardResponse: Bool {
        lock.withLock { returnedForwardResponse }
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/messages/forward-batch" else {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        lock.withLock {
            startedForwardRequest = true
        }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            lock.withLock {
                observedCancellation = true
            }
            if case .waitForCancellation = behavior {
                throw CancellationError()
            }
        }
        let response = try committedResponse(for: request)
        lock.withLock {
            returnedForwardResponse = true
        }
        return response
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    private func committedResponse(for request: URLRequest) throws -> HTTPTransportResult {
        let bodyData = request.httpBody ?? Data()
        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        let clientBatchID = body["client_batch_id"] as? String ?? ""
        let sourceIDs = body["source_message_ids"] as? [String] ?? []
        let targets = body["targets"] as? [[String: Any]] ?? []
        let targetResults = targets.enumerated().map { targetOrdinal, target -> [String: Any] in
            [
                "target_ordinal": targetOrdinal,
                "channel_id": target["channel_id"] as? String ?? "",
                "channel_type": target["channel_type"] as? String ?? "",
                "messages": sourceIDs.enumerated().map { sourceOrdinal, sourceID in
                    [
                        "source_ordinal": sourceOrdinal,
                        "source_message_id": sourceID,
                        "message_id": "created-\(targetOrdinal)-\(sourceOrdinal)"
                    ] as [String: Any]
                }
            ]
        }
        let payload: [String: Any] = [
            "ok": true,
            "data": [
                "contract_version": 1,
                "batch_id": "late-batch",
                "client_batch_id": clientBatchID,
                "source_count": sourceIDs.count,
                "target_count": targets.count,
                "created_count": sourceIDs.count * targets.count,
                "state": "committed",
                "idempotent_replay": false,
                "authoritative_source_message_ids": sourceIDs,
                "targets": targetResults
            ]
        ]
        return HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: payload),
            isHTTPResponse: true,
            statusCode: 201
        )
    }
}

private final class VideoCallStartHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let outgoingPolicyFixture: Bool
    private let fileConfigDelayNanoseconds: UInt64
    private let providerStatusCode: Int
    private let fileConfigStatusCode: Int
    private let providerErrorCode: String
    private let voiceEnabled: Bool
    private let fileConfigDecision: SuspendedBoolDecision?
    private let providerOmitsLicense: Bool
    private let providerNetworkFailure: Bool
    private let providerVideoEnabled: Bool
    private let incomingVideoJoinDecision: SuspendedBoolDecision?
    private var pathCounts: [String: Int] = [:]

    init(
        fileConfigDelayNanoseconds: UInt64,
        providerStatusCode: Int,
        incomingVideoJoinDecision: SuspendedBoolDecision? = nil,
        voiceEnabled: Bool = true,
        providerErrorCode: String = "rtc_provider_unavailable",
        fileConfigStatusCode: Int = 200,
        fileConfigDecision: SuspendedBoolDecision? = nil,
        providerOmitsLicense: Bool = false,
        providerNetworkFailure: Bool = false,
        providerVideoEnabled: Bool = true,
        outgoingPolicyFixture: Bool = false
    ) {
        self.outgoingPolicyFixture = outgoingPolicyFixture
        self.fileConfigDelayNanoseconds = fileConfigDelayNanoseconds
        self.providerStatusCode = providerStatusCode
        self.fileConfigStatusCode = fileConfigStatusCode
        self.providerErrorCode = providerErrorCode
        self.voiceEnabled = voiceEnabled
        self.fileConfigDecision = fileConfigDecision
        self.providerOmitsLicense = providerOmitsLicense
        self.providerNetworkFailure = providerNetworkFailure
        self.providerVideoEnabled = providerVideoEnabled
        self.incomingVideoJoinDecision = incomingVideoJoinDecision
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            pathCounts[path, default: 0] += 1
        }
        if outgoingPolicyFixture {
            if path == "/api/rtc/calls", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let mode = body?["call_type"] as? String ?? "audio"
                return jsonResult(statusCode: 200, body: """
                {"ok":true,"data":{"call":{"id":"policy-call","room_id":"policy-room","status":"ringing","call_type":"\(mode)","caller_uid":"uid-1","callee_uid":"policy-peer","state_version":1},"rtc_token":"policy-test-token"}}
                """)
            }
            if path == "/api/rtc/rooms/policy-room/join" {
                return jsonResult(statusCode: 409, body: #"{"ok":false,"error":{"code":"rtc_transport_policy_pending","message":"pending"}}"#)
            }
            if path == "/api/rtc/device-capabilities" || path == "/api/rtc/calls/policy-call/cancel" {
                return jsonResult(statusCode: 200, body: #"{"ok":true,"data":{}}"#)
            }
        }
        switch path {
        case "/api/tenant/files/config":
            _ = await fileConfigDecision?.wait()
            if fileConfigDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: fileConfigDelayNanoseconds)
            }
            if fileConfigStatusCode != 200 {
                return jsonResult(statusCode: fileConfigStatusCode, body: #"{"ok":false,"error":{"code":"rtc_license_capabilities_unavailable","message":"redacted"}}"#)
            }
            return jsonResult(
                statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "file_upload_max_bytes": 20971520,
                    "max_mb": 20,
                    "source": "test",
                    "message_recall_max_minutes": 120,
                    "voice_call_enabled": \(voiceEnabled),
                    "video_call_enabled": true,
                    "read_receipts_enabled": true,
                    "group_admin_delete_message_enabled": false
                  }
                }
                """
            )
        case "/api/rtc/provider":
            if providerNetworkFailure { throw URLError(.notConnectedToInternet) }
            if providerStatusCode == 200 {
                let licenseFields = providerOmitsLicense ? "" : "\"voice_call_enabled\":\(voiceEnabled),\"video_call_enabled\":\(providerVideoEnabled),"
                return jsonResult(
                    statusCode: 200,
                    body: """
                    {
                      "ok": true,
                      "data": {
                        "call_types": ["audio", "video"],
                        \(licenseFields)
                        "video_supported": true,
                        "capabilities_version": "video-call-v1",
                        "ice_transport_policy_version": \(outgoingPolicyFixture ? 1 : 0),
                        "media_plane_configured": true,
                        "ice_servers_configured": true
                      }
                    }
                    """
                )
            }
            return jsonResult(
                statusCode: providerStatusCode,
                body: """
                {
                  "ok": false,
                  "error": {
                    "code": "\(providerErrorCode)",
                    "message": "测试视频服务暂不可用"
                  }
                }
                """
            )
        case "/api/rtc/calls/incoming-video-after-accept/accept":
            return jsonResult(
                statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "call": {
                      "id": "incoming-video-after-accept",
                      "room_id": "incoming-video-room",
                      "status": "accepted",
                      "call_type": "video",
                      "requested_media_mode": "video",
                      "media_mode": "audio",
                      "caller_uid": "incoming-video-peer",
                      "callee_uid": "uid-1"
                    },
                    "rtc_token": "incoming-video-token"
                  }
                }
                """
            )
        case "/api/rtc/rooms/incoming-video-room/join":
            _ = await incomingVideoJoinDecision?.wait()
            return jsonResult(
                statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "room_id": "incoming-video-room",
                    "rtc_token": "incoming-video-token",
                    "media": {
                      "owt_base_url": "https://rtc.example.test",
                      "ice_servers": []
                    },
                    "participants": []
                  }
                }
                """
            )
        case "/api/rtc/calls/incoming-video-after-accept/hangup":
            return jsonResult(
                statusCode: 200,
                body: """
                {"ok":true,"data":{}}
                """
            )
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestCount(path: String) -> Int {
        lock.withLock { pathCounts[path, default: 0] }
    }

    private func jsonResult(statusCode: Int, body: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: statusCode
        )
    }
}

private actor SuspendedBoolDecision {
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func resume(returning value: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

private actor FirstJoinSuspensionGate {
    private var joinCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func passOrSuspendFirst() async {
        joinCount += 1
        guard joinCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func isWaiting() -> Bool {
        firstContinuation != nil
    }

    func resumeFirst() {
        let pending = firstContinuation
        firstContinuation = nil
        pending?.resume()
    }
}

private actor SequencedBoolDecision {
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next(default fallback: Bool = false) -> Bool {
        guard !values.isEmpty else { return fallback }
        return values.removeFirst()
    }
}

// WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: provider and file config keep the same independently selectable voice license.
// WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: faithful response origins/capabilities and deterministic async boundaries.
private final class IncomingSameCallOwnershipHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let voiceEnabled: Bool
    private let callID: String
    private let callType: String
    private let peerUID: String
    private let acceptGate: FirstJoinSuspensionGate?
    private let firstJoinGate: FirstJoinSuspensionGate
    private let providerSuccessLimit: Int?
    private let gateStage: String
    private let acceptedMediaMode: String
    private let failJoin: Bool
    private let hangupFailures: Int
    private var mutationKeys: [String: [String]] = [:]
    private var pathCounts: [String: Int] = [:]
    private var authorizationHeaders: [String: [String]] = [:]

    init(
        callID: String,
        callType: String,
        peerUID: String,
        firstJoinGate: FirstJoinSuspensionGate,
        acceptGate: FirstJoinSuspensionGate? = nil,
        providerSuccessLimit: Int? = nil,
        gateStage: String = "join",
        acceptedMediaMode: String = "audio",
        failJoin: Bool = false,
        hangupFailures: Int = 0,
        voiceEnabled: Bool = true
    ) {
        self.voiceEnabled = voiceEnabled
        self.callID = callID
        self.callType = callType
        self.peerUID = peerUID
        self.acceptGate = acceptGate
        self.firstJoinGate = firstJoinGate
        self.providerSuccessLimit = providerSuccessLimit
        self.gateStage = gateStage
        self.acceptedMediaMode = acceptedMediaMode
        self.failJoin = failJoin
        self.hangupFailures = hangupFailures
    }

    func data(
        for request: URLRequest,
        rejectingCrossOriginRedirectsFrom expectedOrigin: URL
    ) async throws -> HTTPTransportResult {
        try await data(for: request).resolvingResponseURL(request.url)
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            pathCounts[path, default: 0] += 1
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let key = json["idempotency_key"] as? String {
                mutationKeys[path, default: []].append(key)
            }
            if let authorization = request.value(forHTTPHeaderField: "Authorization") {
                authorizationHeaders[path, default: []].append(authorization)
            }
        }
        switch path {
        case "/api/tenant/files/config":
            if gateStage == "files" { await firstJoinGate.passOrSuspendFirst() }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "file_upload_max_bytes":20971520,
                  "max_mb":20,
                  "source":"test",
                  "message_recall_max_minutes":120,
                  "voice_call_enabled":\(voiceEnabled),
                  "video_call_enabled":true,
                  "read_receipts_enabled":true,
                  "group_admin_delete_message_enabled":false
                }}
                """
            )
        case "/api/rtc/provider":
            if gateStage == "provider" { await firstJoinGate.passOrSuspendFirst() }
            if let providerSuccessLimit,
               requestCount(path: path) > providerSuccessLimit {
                return jsonResult(
                    """
                    {"ok":false,"error":{
                      "code":"rtc_provider_unavailable",
                      "message":"replacement provider denied"
                    }}
                    """,
                    statusCode: 503
                )
            }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "call_types":["audio","video"],
                  "voice_call_enabled":\(voiceEnabled),
                  "video_call_enabled":true,
                  "capabilities_version":"video-call-v1",
                  "video_supported":true,
                  "media_plane_configured":true,
                  "ice_servers_configured":true
                }}
                """
            )
        case "/api/rtc/calls/\(callID)/accept":
            if let acceptGate { await acceptGate.passOrSuspendFirst() }
            let requestedMode = callType == "video" ? "video" : "audio"
            return jsonResult(
                """
                {"ok":true,"data":{
                  "call":{
                    "id":"\(callID)",
                    "room_id":"\(callID)-room",
                    "status":"accepted",
                    "call_type":"\(callType)",
                    "requested_media_mode":"\(requestedMode)",
                    "media_mode":"\(acceptedMediaMode)",
                    "caller_uid":"\(peerUID)",
                    "callee_uid":"uid-1",
                    "caller_device":{
                      "uid":"\(peerUID)",
                      "device_id":"peer-device",
                      "device_type":"web"
                    },
                    "callee_device":{
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios"
                    },
                    "accepted_device":{
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios"
                    }
                  },
                  "rtc_token":"\(callID)-token"
                }}
                """
            )
        case "/api/rtc/rooms/\(callID)-room/join":
            if gateStage == "join" { await firstJoinGate.passOrSuspendFirst() }
            if failJoin { throw URLError(.cannotConnectToHost) }
            if gateStage == "participants" {
                return jsonResult("""
                {"ok":true,"data":{
                  "room_id":"\(callID)-room","rtc_token":"\(callID)-token",
                  "media":{"owt_base_url":"https://rtc.example.test","ice_servers":[]},
                  "self_participant":{"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"},
                  "participants":[{"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"}]
                }}
                """)
            }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "room_id":"\(callID)-room",
                  "rtc_token":"\(callID)-token",
                  "media":{
                    "owt_base_url":"https://rtc.example.test",
                    "ice_servers":[]
                  },
                  "self_participant":{
                    "uid":"uid-1",
                    "device_id":"unit-test-device",
                    "device_type":"ios",
                    "role":"self"
                  },
                  "peer_participant":{
                    "uid":"\(peerUID)",
                    "device_id":"peer-stale-device",
                    "device_type":"web",
                    "role":"peer"
                  },
                  "participants":[
                    {
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios",
                      "role":"self"
                    },
                    {
                      "uid":"\(peerUID)",
                      "device_id":"peer-stale-device",
                      "device_type":"web",
                      "role":"peer"
                    },
                    {
                      "uid":"\(peerUID)",
                      "device_id":"peer-device",
                      "device_type":"web",
                      "role":"peer"
                    }
                  ]
                }}
                """
            )
        case "/api/rtc/rooms/\(callID)-room/participants":
            await firstJoinGate.passOrSuspendFirst()
            return jsonResult("""
            {"ok":true,"data":{"items":[
              {"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"},
              {"uid":"\(peerUID)","device_id":"peer-device","device_type":"web","role":"peer"}
            ]}}
            """)
        case "/api/rtc/rooms/\(callID)-room/signals":
            return jsonResult(#"{"ok":true,"data":{"items":[],"next_cursor":"next","has_more":false}}"#)
        case "/api/rtc/rooms/\(callID)-room/ice-credentials":
            return jsonResult(#"{"ok":true,"data":{"ice_servers":[],"rtc_token":"rtc-refreshed","ice_credential_expires_at":"","ice_credential_refresh_after":""}}"#)
        case "/api/rtc/calls/\(callID)/hangup", "/api/rtc/calls/\(callID)/downgrade":
            if path.hasSuffix("/hangup"), requestCount(path: path) <= hangupFailures {
                return jsonResult(#"{"ok":false,"error":{"code":"temporary_unavailable","message":"retry"}}"#, statusCode: 503)
            }
            return jsonResult(#"{"ok":true,"data":{}}"#)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestCount(path: String) -> Int {
        lock.withLock { pathCounts[path, default: 0] }
    }

    func idempotencyKeys(path: String) -> [String] {
        lock.withLock { mutationKeys[path] ?? [] }
    }

    func authorizationHeader(path: String) -> String? {
        lock.withLock { authorizationHeaders[path]?.last }
    }

    private func jsonResult(
        _ body: String,
        statusCode: Int = 200
    ) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: statusCode
        )
    }
}

// WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END
// WDT_IOS1_CALLKIT_ANSWER_20260921_END

private final class RTCSystemEndHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var remainingFailuresByPath: [String: Int]
    private let failureDelayNanoseconds: UInt64
    private let fileConfigDecision: SuspendedBoolDecision?
    private let fileConfigLicenseFields: String?

    init(
        remainingFailuresByPath: [String: Int] = [:],
        failureDelayNanoseconds: UInt64 = 0,
        fileConfigDecision: SuspendedBoolDecision? = nil,
        fileConfigLicenseFields: String? = nil
    ) {
        self.remainingFailuresByPath = remainingFailuresByPath
        self.failureDelayNanoseconds = failureDelayNanoseconds
        self.fileConfigDecision = fileConfigDecision
        self.fileConfigLicenseFields = fileConfigLicenseFields
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: same-origin provider responses must reach the suspended permission boundary.
        if request.httpMethod == "GET", request.url?.path == "/api/tenant/files/config",
           let fileConfigLicenseFields {
            let first = requestCount(path: "/api/tenant/files/config") == 1
            if first { _ = await fileConfigDecision?.wait() }
            return HTTPTransportResult(
                data: Data("{\"ok\":true,\"data\":{\(fileConfigLicenseFields)\"source\":\"test\",\"max_mb\":20}}".utf8),
                isHTTPResponse: true, statusCode: 200
            )
        }
        if request.httpMethod == "GET", request.url?.path == "/api/rtc/provider", fileConfigLicenseFields != nil {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"voice_call_enabled":true,"video_call_enabled":true,"video_supported":true,"call_types":["audio","video"],"media_plane_configured":true,"ice_servers_configured":true}}"#.utf8),
                isHTTPResponse: true, statusCode: 200
            )
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_END
        if request.httpMethod == "GET", request.url?.path == "/api/rtc/calls" {
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":true,"data":{"calls":[{"id":"call-first","status":"ringing","room_id":"room-first","caller_uid":"friend-1","callee_uid":"uid-1","channel_id":"friend-1:uid-1","channel_type":"direct","call_type":"audio","state_version":1}]}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        guard request.httpMethod == "POST",
              ["/reject", "/cancel", "/hangup", "/downgrade"].contains(where: {
                  request.url?.path.hasSuffix($0) == true
              }) else {
            throw URLError(.unsupportedURL)
        }
        let path = request.url?.path ?? ""
        let shouldFail = lock.withLock { () -> Bool in
            let remaining = remainingFailuresByPath[path] ?? 0
            guard remaining > 0 else { return false }
            remainingFailuresByPath[path] = remaining - 1
            return true
        }
        if shouldFail {
            if failureDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: failureDelayNanoseconds)
            }
            return HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"temporary_unavailable","message":"retry"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        }
        return HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requestCount(path: String) -> Int {
        lock.withLock {
            capturedRequests.filter { $0.url?.path == path }.count
        }
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func idempotencyKeys(path: String) -> [String] {
        lock.withLock {
            capturedRequests
                .filter { $0.url?.path == path }
                .compactMap { request -> String? in
                    guard let body = request.httpBody,
                          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        return nil
                    }
                    return object["idempotency_key"] as? String
                }
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
}

private final class RTCDeviceCapabilityBootstrapHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let capabilityStatusCode: Int
    private var capturedRequests: [URLRequest] = []

    init(capabilityStatusCode: Int = 200) {
        self.capabilityStatusCode = capabilityStatusCode
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        switch request.url?.path ?? "" {
        case "/api/tenant/files/config":
            return HTTPTransportResult(
                data: Data(
                    """
                    {
                      "ok": true,
                      "data": {
                        "file_upload_max_bytes": 20971520,
                        "max_mb": 20,
                        "source": "test",
                        "message_recall_max_minutes": 120,
                        "voice_call_enabled": true,
                        "video_call_enabled": true,
                        "read_receipts_enabled": true,
                        "group_admin_delete_message_enabled": false
                      }
                    }
                    """.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        case "/api/rtc/device-capabilities":
            if capabilityStatusCode == 200 {
                return HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            }
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":false,"error":{"code":"rtc_capability_unavailable","message":"capability unavailable"}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: capabilityStatusCode
            )
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requestCount(path: String) -> Int {
        lock.withLock {
            capturedRequests.filter { $0.url?.path == path }.count
        }
    }

    func lastJSONBody(path: String) -> [String: Any]? {
        lock.withLock {
            guard let body = capturedRequests.last(where: { $0.url?.path == path })?.httpBody else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }
}

private final class SearchJumpTargetHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let syncItemsJSON: String
    private var capturedBodies: [[String: Any]] = []

    init(syncItemsJSON: String) {
        self.syncItemsJSON = syncItemsJSON
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/sync" else {
            throw URLError(.unsupportedURL)
        }
        if let bodyData = request.httpBody,
           let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            lock.withLock {
                capturedBodies.append(body)
            }
        }
        let json = #"{"ok":true,"data":{"items":\#(syncItemsJSON),"total":0}}"#
        return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestBodies() -> [[String: Any]] {
        lock.withLock { capturedBodies }
    }
}

private final class SystemInboxReadHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            paths.append(path)
        }
        switch path {
        case "/api/tenant/inbox/system/read":
            let json = #"{"ok":true,"data":{"items":[]}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        case "/api/tenant/inbox":
            let json = """
            {
              "ok": true,
              "data": {
                "items": [
                  {
                    "id": "system-2",
                    "kind": "system",
                    "title": "通知二",
                    "summary": "内容二",
                    "created_at": "2026-06-28T03:01:00Z"
                  },
                  {
                    "id": "system-1",
                    "kind": "system",
                    "title": "通知一",
                    "summary": "内容一",
                    "created_at": "2026-06-28T03:00:00Z"
                  }
                ]
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        case "/api/im/read-ack":
            let json = #"{"ok":false,"error":{"code":"read_ack_unavailable","message":"read ack unavailable"}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        case "/api/im/conversations/sync":
            let json = #"{"ok":false,"error":{"code":"snapshot_unavailable","message":"snapshot unavailable"}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestPaths() -> [String] {
        lock.withLock { paths }
    }
}

private actor FirstReadAckSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func resumeFirst() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class ReadAckCoalescingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstRequestGate: FirstReadAckSuspensionGate
    private let failSecondRequest: Bool
    private var sequences: [Int64] = []

    init(firstRequestGate: FirstReadAckSuspensionGate, failSecondRequest: Bool = false) {
        self.firstRequestGate = firstRequestGate
        self.failSecondRequest = failSecondRequest
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/read-ack",
              let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let number = body["channel_seq"] as? NSNumber else {
            throw URLError(.unsupportedURL)
        }
        let sequence = number.int64Value
        let requestIndex = lock.withLock { () -> Int in
            sequences.append(sequence)
            return sequences.count
        }
        if requestIndex == 1 {
            await firstRequestGate.wait()
        }
        if requestIndex == 2, failSecondRequest {
            return HTTPTransportResult(
                data: Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\"}}".utf8),
                isHTTPResponse: true,
                statusCode: 500
            )
        }
        let json = """
        {"ok":true,"data":{"channel_id":"read-convergence-group","channel_type":"group","last_read_seq":\(sequence),"read_receipts":[]}}
        """
        return HTTPTransportResult(
            data: Data(json.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestedSequences() -> [Int64] {
        lock.withLock { sequences }
    }
}

private final class LifecycleReadAckHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let suspendedRequestNumber: Int
    private let gate: FirstReadAckSuspensionGate
    private var sequences: [Int64] = []

    init(suspendedRequestNumber: Int, gate: FirstReadAckSuspensionGate) {
        self.suspendedRequestNumber = suspendedRequestNumber
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/read-ack",
              let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let number = body["channel_seq"] as? NSNumber else {
            throw URLError(.unsupportedURL)
        }
        let requestNumber = lock.withLock { () -> Int in
            sequences.append(number.int64Value)
            return sequences.count
        }
        if requestNumber == suspendedRequestNumber {
            await gate.wait()
        }
        return HTTPTransportResult(
            data: Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\"}}".utf8),
            isHTTPResponse: true,
            statusCode: 500
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestCount() -> Int {
        lock.withLock { sequences.count }
    }
}

private final class EnterpriseProfileRefreshHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let tenantContextRole: String?
    private let workspaceItemsJSON: String
    private let tenantContextDevicePolicyJSON: String?

    init(
        tenantContextRole: String? = nil,
        workspaceItemsJSON: String? = nil,
        tenantContextDevicePolicyJSON: String? = nil
    ) {
        self.tenantContextRole = tenantContextRole
        self.tenantContextDevicePolicyJSON = tenantContextDevicePolicyJSON
        self.workspaceItemsJSON = workspaceItemsJSON ?? """
                  {
                    "id": "tenant-1",
                    "tenantCode": "WXT000001",
                    "tenantName": "后台改名企业",
                    "status": "enabled",
                    "join_status": "joined",
                    "member_status": "normal",
                    "member_role": "member",
                    "can_switch": true,
                    "enterable": true,
                    "current": true,
                    "logo_url": "/api/tenant/avatar/logo-v1.png",
                    "logo_status": "ready",
                    "logo_cache_key": "logo-v1"
                  }
        """
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            paths.append(path)
        }
        let json: String
        switch path {
        case "/api/platform/apps/current-policy":
            json = """
            {
              "ok": true,
              "data": {
                "app_id": "jht-ios-main",
                "platform": "ios",
                "status": "enabled",
                "allow_workspace_switch": true,
                "allow_default_tenant_join": true,
                "require_real_name": false,
                "require_phone_verification": false,
                "cache_ttl_seconds": 60
              }
            }
            """
        case "/api/tenant/workspaces":
            json = """
            {
              "ok": true,
              "data": {
                "items": [
                  \(workspaceItemsJSON)
                ]
              }
            }
            """
        case "/api/tenant/context":
            guard let tenantContextRole else {
                throw URLError(.unsupportedURL)
            }
            let devicePolicyField = tenantContextDevicePolicyJSON.map { ",\"device\":\($0)" } ?? ""
            json = """
            {
              "ok": true,
              "data": {
                "tenant_id": "tenant-1",
                "im_uid": "uid-1",
                "app_id": "\(IMAPIContext.canonicalIOSAppID)",
                "device_id": "unit-test-device",
                "tenant": {
                  "id": "tenant-1",
                  "tenantCode": "WXT000001",
                  "tenantName": "后台改名企业",
                  "status": "enabled",
                  "logo_url": "/api/tenant/avatar/logo-v2.png",
                  "logo_status": "ready",
                  "logo_version": "logo-v2",
                  "logo_cache_key": "logo-v2"
                },
                "user": {
                  "im_uid": "uid-1",
                  "user_id": "WXTNS000100",
                  "username": "admin22",
                  "nickname": "年明然",
                  "status": "normal",
                  "role": "\(tenantContextRole)"
                },
                "tenant_policy": {
                  "group": {
                    "allow_member_group_creation": false
                  }\(devicePolicyField)
                }
              }
            }
            """
        case "/api/tenant/profile":
            json = """
            {
              "ok": true,
              "data": {
                "id": "tenant-1",
                "tenantCode": "WXT000001",
                "tenantName": "旧企业",
                "status": "enabled",
                "logo_url": "/api/tenant/avatar/logo-v2.png",
                "logo_status": "ready",
                "logo_version": "logo-v2",
                "logo_updated_at": "2026-06-27T10:00:00Z",
                "logo_cache_key": "logo-v2"
              }
            }
            """
        default:
            throw URLError(.unsupportedURL)
        }
        return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestPaths() -> [String] {
        lock.withLock { paths }
    }
}

private final class TenantDevicePolicyRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstTenantContextGate: FirstReadAckSuspensionGate
    private var tenantContextRequestCount = 0

    init(firstTenantContextGate: FirstReadAckSuspensionGate) {
        self.firstTenantContextGate = firstTenantContextGate
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        switch path {
        case "/api/tenant/workspaces":
            return result(#"{"ok":true,"data":{"items":[]}}"#)
        case "/api/tenant/profile":
            return result(#"{"ok":true,"data":{"id":"tenant-1","tenantCode":"WXT000001","tenantName":"Tenant","status":"enabled"}}"#)
        case "/api/tenant/context":
            let requestIndex = lock.withLock { () -> Int in
                tenantContextRequestCount += 1
                return tenantContextRequestCount
            }
            if requestIndex == 1 {
                await firstTenantContextGate.wait()
            }
            let enabled = requestIndex == 1 ? "false" : "true"
            return result("""
            {
              "ok": true,
              "data": {
                "tenant_id": "tenant-1",
                "im_uid": "uid-1",
                "app_id": "\(IMAPIContext.canonicalIOSAppID)",
                "device_id": "unit-test-device",
                "tenant": {"id":"tenant-1","tenantCode":"WXT000001","tenantName":"Tenant","status":"enabled"},
                "tenant_policy": {
                  "device": {
                    "multi_device_enabled": \(enabled),
                    "authoritative": true,
                    "contract_version": 1
                  }
                }
              }
            }
            """)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func tenantContextRequests() -> Int {
        lock.withLock { tenantContextRequestCount }
    }

    private func result(_ json: String) -> HTTPTransportResult {
        HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }
}

@MainActor
private final class DeviceKickRealtimeTransport: RealtimeTransporting {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)?
    private(set) var disconnectCalls: [Bool] = []
    private(set) var isConnected = true

    func start(url: URL, token: String) {
        isConnected = true
    }

    func disconnect(shouldReconnect: Bool) {
        disconnectCalls.append(shouldReconnect)
        isConnected = false
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {}
}

private final class StickerPanelHydrationHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedPaths: [String] = []

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            capturedPaths.append(path)
        }
        if path == "/api/tenant/files/file-cached" {
            let json = """
            {
              "ok": true,
              "data": {
                "file": {
                  "id": "file-cached",
                  "file_name": "cached-sticker.gif",
                  "mime_type": "image/gif",
                  "size_bytes": 4096,
                  "status": "uploaded",
                  "cache_key": "cache-cached",
                  "version": "v1",
                  "checksum": "checksum-cached",
                  "thumbnail_url": "https://cdn.example.test/file-cached-thumb.gif?sig=unit",
                  "width": 128,
                  "height": 128,
                  "duration_ms": 600
                },
                "preview_available": true,
                "download_available": true,
                "preview_url": "https://cdn.example.test/file-cached-preview.gif?sig=unit",
                "download_url": "https://cdn.example.test/file-cached.gif?sig=unit"
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        }
        if path == "/api/tenant/user-stickers" {
            let json = """
            {
              "ok": false,
              "error": {
                "code": "temporarily_unavailable",
                "message": "temporarily unavailable"
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        }
        throw URLError(.unsupportedURL)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func paths() -> [String] {
        lock.withLock { capturedPaths }
    }
}

private final class TestVoiceCallSystemIntegration: VoiceCallSystemIntegrating, @unchecked Sendable {
    private let continuation: AsyncStream<VoiceCallSystemEvent>.Continuation
    private var presentedCallIDs: Set<String>
    private(set) var started = false
    private(set) var endedCalls: [(callID: String, reason: String)] = []
    private(set) var reportedPayloads: [RTCVoIPPushPayload] = []
    let events: AsyncStream<VoiceCallSystemEvent>

    init(presentedCallIDs: Set<String> = []) {
        self.presentedCallIDs = presentedCallIDs
        var streamContinuation: AsyncStream<VoiceCallSystemEvent>.Continuation!
        events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func start() {
        started = true
    }

    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool {
        reportedPayloads.append(payload)
        presentedCallIDs.insert(payload.callID)
        return true
    }

    func endCall(callID: String, reason: String) {
        endedCalls.append((callID: callID, reason: reason))
        presentedCallIDs.remove(callID)
    }

    func setMuted(callID: String, isMuted: Bool) {}

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN
    private(set) var requestedAnswers: [String] = []
    var answerRequestError: Error?
    var onAnswerRequest: (@MainActor (String) -> Void)?
    func answerPresentedCall(callID: String) async throws {
        requestedAnswers.append(callID)
        if let answerRequestError { throw answerRequestError }
        if let onAnswerRequest { await onAnswerRequest(callID) }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END

    func hasPresentedCall(callID: String) -> Bool {
        presentedCallIDs.contains(callID)
    }

    func clearPresentedCall(callID: String) {
        presentedCallIDs.remove(callID)
    }

    func emit(_ event: VoiceCallSystemEvent) {
        continuation.yield(event)
    }
}

private final class RTCMediaHeartbeatHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        let result: HTTPTransportResult
        let delayNanoseconds: UInt64
        let ignoresCancellation: Bool

        init(
            result: HTTPTransportResult,
            delayNanoseconds: UInt64 = 0,
            ignoresCancellation: Bool = false
        ) {
            self.result = result
            self.delayNanoseconds = delayNanoseconds
            self.ignoresCancellation = ignoresCancellation
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var capturedRequests: [URLRequest] = []
    private var concurrentRequests = 0
    private(set) var maximumConcurrentRequests = 0

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path == "/api/platform/apps/current-policy" {
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":true,"data":{"app_id":"jianhuitong-ios","phone_auth_enabled":true}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        let path = request.url?.path ?? ""
        if path.hasSuffix("/hangup") || path.hasSuffix("/cancel") {
            lock.withLock { capturedRequests.append(request) }
        }
        guard path.hasSuffix("/media-state") || path.hasSuffix("/join") else {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        let stub: Stub = lock.withLock {
            capturedRequests.append(request)
            concurrentRequests += 1
            maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
            if stubs.isEmpty {
                return Stub(
                    result: HTTPTransportResult(
                        data: Data(#"{"ok":true,"data":{}}"#.utf8),
                        isHTTPResponse: true,
                        statusCode: 200
                    )
                )
            }
            return stubs.removeFirst()
        }
        defer {
            lock.withLock {
                concurrentRequests = max(0, concurrentRequests - 1)
            }
        }
        if stub.delayNanoseconds > 0 {
            if stub.ignoresCancellation {
                try? await Task.sleep(nanoseconds: stub.delayNanoseconds)
            } else {
                try await Task.sleep(nanoseconds: stub.delayNanoseconds)
            }
        }
        return stub.result
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

private final class TestVideoMediaClient: VideoMediaClient {
    var isAvailable: Bool { true }
    var cameraAvailable: Bool { true }
    private(set) var stopReasons: [String] = []
    var speakerError: Error?
    var cameraError: Error?
    var switchCameraError: Error?
    var downgradeToAudioError: Error?
    var foregroundError: Error?
    var audioReconcileError: Error?
    private(set) var speakerValues: [Bool] = []
    private(set) var cameraValues: [Bool] = []
    private(set) var switchCameraCount = 0
    private(set) var downgradeToAudioCount = 0
    private(set) var backgroundCount = 0
    private(set) var foregroundCount = 0
    private(set) var audioReconcileCount = 0
    private(set) var startCount = 0
    var firstPrepareDecision: SuspendedBoolDecision?
    private(set) var prepareCount = 0
    private(set) var preparedGeneration: Int?
    private(set) var previewEvents: [String] = []

    func preparePreview(preferFrontCamera: Bool) async throws {
        prepareCount += 1
        let generation = prepareCount
        previewEvents.append("prepare:\(generation)")
        if generation == 1 { _ = await firstPrepareDecision?.wait() }
        preparedGeneration = generation
        previewEvents.append("prepared:\(generation)")
    }

    func start(
        context: VideoMediaSessionContext,
        cameraEnabled: Bool
    ) async throws -> AsyncStream<RTCVideoMediaEvent> {
        startCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {}
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        speakerValues.append(isEnabled)
        if let speakerError { throw speakerError }
    }
    func setCameraEnabled(_ isEnabled: Bool) async throws {
        cameraValues.append(isEnabled)
        if let cameraError { throw cameraError }
    }
    func switchCamera() async throws {
        switchCameraCount += 1
        if let switchCameraError { throw switchCameraError }
    }
    func downgradeToAudio() async throws {
        downgradeToAudioCount += 1
        if let downgradeToAudioError { throw downgradeToAudioError }
    }
    func applicationDidEnterBackground() async {
        backgroundCount += 1
    }
    func applicationWillEnterForeground() async throws {
        foregroundCount += 1
        if let foregroundError { throw foregroundError }
    }
    func reconcileAudioSessionAfterSystemEvent() async throws {
        audioReconcileCount += 1
        if let audioReconcileError { throw audioReconcileError }
    }

    func stop(reason: String) async {
        stopReasons.append(reason)
        preparedGeneration = nil
        previewEvents.append("stop")
    }
}

@MainActor
private final class TestVoiceMediaClient: VoiceMediaClient {
    var isAvailable: Bool { true }
    private let events: [RTCVoiceMediaEvent]
    private var startErrors: [Error]
    private(set) var startedContexts: [VoiceMediaSessionContext] = []
    private(set) var speakerValues: [Bool] = []
    private(set) var mutedValues: [Bool] = []
    private(set) var stopReasons: [String] = []
    private(set) var audioReconcileSpeakerValues: [Bool] = []

    init(events: [RTCVoiceMediaEvent] = [], startErrors: [Error] = []) {
        self.events = events
        self.startErrors = startErrors
    }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        startedContexts.append(context)
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        let events = self.events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {
        mutedValues.append(isMuted)
    }

    func setSpeakerEnabled(_ isEnabled: Bool) async {
        speakerValues.append(isEnabled)
    }

    func reconcileAudioSessionAfterSystemEvent(speakerOn: Bool) async throws {
        audioReconcileSpeakerValues.append(speakerOn)
    }

    func stop(reason: String) async {
        stopReasons.append(reason)
    }
}

@MainActor
private final class RecordingBiometricAuthenticator: LocalBiometricAuthenticating, @unchecked Sendable {
    private let error: Error?
    private(set) var requestCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws {
        XCTAssertFalse(reason.isEmpty)
        requestCount += 1
        if let error {
            throw error
        }
    }
}

@MainActor
private final class SuspendedBiometricAuthenticator: LocalBiometricAuthenticating, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var shouldSucceedNextRequest = false
    private(set) var requestCount = 0

    var isWaiting: Bool { continuation != nil }

    func authenticate(reason: String) async throws {
        XCTAssertFalse(reason.isEmpty)
        requestCount += 1
        if shouldSucceedNextRequest {
            shouldSucceedNextRequest = false
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        if let pending = continuation {
            continuation = nil
            pending.resume()
        } else {
            shouldSucceedNextRequest = true
        }
    }
}

@MainActor
final class IOSNotificationStateMachineTests: XCTestCase {
    func testFirstActiveNotificationAuthorizationPolicyRequestsOnceAndNeverLoopsDenied() {
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .notDetermined, didRequestThisProcess: false),
            .requestAuthorization
        )
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .notDetermined, didRequestThisProcess: true),
            .none
        )
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .denied, didRequestThisProcess: false),
            .none
        )
        for status in [
            IOSNotificationAuthorizationStatus.authorized,
            .provisional,
            .ephemeral
        ] {
            XCTAssertEqual(
                IOSNotificationAuthorizationPolicy.action(status: status, didRequestThisProcess: false),
                .registerRemoteNotifications
            )
        }
    }

    func testPermissionCoordinatorRequestsNotDeterminedOnceAndKeepsPushKitIndependent() async {
        let deniedManager = RecordingNotificationAuthorizationManager(status: .notDetermined)
        deniedManager.statusAfterRequest = .denied
        let deniedCoordinator = IOSNotificationPermissionCoordinator(manager: deniedManager)

        let firstDeniedStatus = await deniedCoordinator.sceneDidBecomeActive()
        let secondDeniedStatus = await deniedCoordinator.sceneDidBecomeActive()
        XCTAssertEqual(firstDeniedStatus, .denied)
        XCTAssertEqual(secondDeniedStatus, .denied)
        XCTAssertEqual(deniedManager.requestCount, 1)
        XCTAssertEqual(deniedManager.registrationCount, 0)

        let authorizedManager = RecordingNotificationAuthorizationManager(status: .authorized)
        let authorizedCoordinator = IOSNotificationPermissionCoordinator(manager: authorizedManager)
        let authorizedStatus = await authorizedCoordinator.sceneDidBecomeActive()
        XCTAssertEqual(authorizedStatus, .authorized)
        XCTAssertEqual(authorizedManager.requestCount, 0)
        XCTAssertEqual(authorizedManager.registrationCount, 1)

        let appDelegateSource = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("BlueStoneIM/BlueStoneIMApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appDelegateSource?.contains("CallKitPushVoiceCallManager.shared.start()") == true)
    }

    func testLifecyclePolicySeparatesForegroundBackgroundAndTerminatedPresentation() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-42",
            "aggregate_id": "message-42",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope"
        ]))

        XCTAssertEqual(payload.title, "收到新消息通知")
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .foregroundVisible, payload: payload), .inAppWithSound)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .backgroundAlive, payload: payload), .localSystemNotification)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .backgroundSuspended, payload: payload), .systemAPNsNotification)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .terminated, payload: payload), .systemAPNsNotification)
    }

    func testNotificationDeliveryKeepsExecutableBackgroundLocalAndSuspendedAPNsPathsDistinct() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-background-1",
            "aggregate_id": "conversation-background-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope"
        ]))

        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .backgroundAlive, payload: payload),
            .localSystemNotification,
            "only an executing background process may create the local system notification"
        )
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .backgroundSuspended, payload: payload),
            .systemAPNsNotification,
            "a suspended process must rely on APNs rather than assume local code can run"
        )
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .terminated, payload: payload),
            .systemAPNsNotification
        )
    }

    func testOpaqueNotificationTargetAndMentionAttentionRemainPrivacyMinimal() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-opaque",
            "aggregate_id": "aggregate-opaque",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope",
            "target_ref": "target-ref-opaque",
            "attention": "mention",
            "sender_name": "must-not-be-used",
            "body": "must-not-be-used"
        ]))

        XCTAssertEqual(payload.targetRef, "target-ref-opaque")
        XCTAssertEqual(payload.attention, .mention)
        XCTAssertEqual(payload.title, "收到新消息通知")
        XCTAssertNil(payload.localMetadata)
    }

    func testVoIPTransportPolicyOnlyAllowsTrueRingingInvitation() throws {
        let ringing = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "ringing",
            "call_id": "call-ringing"
        ]))
        let terminal = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "answered_elsewhere",
            "call_id": "call-terminal"
        ]))

        XCTAssertEqual(VoIPPushTransportPolicy.action(for: ringing), .reportIncomingCall)
        XCTAssertEqual(VoIPPushTransportPolicy.action(for: terminal), .ignoreAndReconcile)
    }

    func testCallCopyIsExactAndTerminalEventCancelsWithoutAlert() throws {
        func payload(category: String, presentation: String) throws -> IOSNotificationStatePayload {
            try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
                "schema_version": "notification_state.v1",
                "notification_id": "call-event-7",
                "aggregate_id": "call-7",
                "notification_category": category,
                "presentation": presentation,
                "scope_key": "tenant-scope",
                "type": "rtc_call",
                "event": presentation == "cancel" ? "ended" : "ringing",
                "call_id": "call-7",
                "call_type": category == "video_call" ? "video" : "audio"
            ]))
        }

        XCTAssertEqual(try payload(category: "voice_call", presentation: "alert").title, "收到语音通话请求")
        XCTAssertEqual(try payload(category: "video_call", presentation: "alert").title, "收到视频通话请求")
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(
                processState: .backgroundAlive,
                payload: try payload(category: "video_call", presentation: "cancel")
            ),
            .cancelExisting
        )
        XCTAssertNil(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "incomplete"
        ]))
    }

    func testNotificationPrivacyAuthorityFailsClosedForUnknownAndConflictingCallFields() {
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ringing",
                callType: "audio",
                callID: "voice-1"
            ),
            .voiceCallRequest
        )
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ringing",
                callType: "video",
                callID: "video-1"
            ),
            .videoCallRequest
        )
        for callType in ["", "legacy-video-ish", "语音"] {
            XCTAssertEqual(
                IOSNotificationPrivacyCopy.authoritativeCallRequest(
                    payloadType: "rtc_call",
                    eventType: "ringing",
                    callType: callType,
                    callID: "unknown-1"
                ),
                .generic
            )
        }
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ended",
                callType: "video",
                callID: "ended-1"
            ),
            .generic
        )
    }

    func testLocalNotificationVisibleSurfacesUseOnlyFixedPrivacyCopy() {
        for (kind, expected) in [
            (IOSNotificationPrivacyKind.generic, "收到新消息通知"),
            (.voiceCallRequest, "收到语音通话请求"),
            (.videoCallRequest, "收到视频通话请求")
        ] {
            let content = IOSNotificationRuntime.visibleContent(for: kind)
            XCTAssertEqual(content.title, "问达通")
            XCTAssertEqual(content.body, expected)
            XCTAssertEqual(content.subtitle, "")
            XCTAssertEqual(content.threadIdentifier, "")
            XCTAssertEqual(content.summaryArgument, "")
        }
    }

    func testLocalNotificationMetadataMatchesExactReadWatermarkAndExcludesPrivateFields() throws {
        let record = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: " tenant-a ",
            imUID: " user-a ",
            appID: " app-ios ",
            channelID: " c1 ",
            channelType: " Direct ",
            channelSeq: 7,
            createdAt: "2026-08-26T00:00:00Z"
        ))
        let matching = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 7
        ))
        let lowerWatermark = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 6
        ))
        let otherApp = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "other-app",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 9
        ))

        XCTAssertTrue(record.matches(matching))
        XCTAssertFalse(record.matches(lowerWatermark))
        XCTAssertFalse(record.matches(otherApp))
        XCTAssertNil(IOSNotificationLocalMetadata(
            notificationID: "message-0",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 0
        ))
        XCTAssertNil(IOSNotificationLocalMetadata(
            notificationID: " ",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 1
        ))
        let forbiddenKeys = Set([
            "body", "text", "message", "sender_name", "profile", "avatar", "device_id", "source_device"
        ])
        XCTAssertTrue(forbiddenKeys.isDisjoint(with: Set(record.userInfo.keys)))
    }

    func testRuntimeCancelReadWatermarkRemovesPendingDeliveredIdentifiersAndPrunesIndex() throws {
        let matched = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-5",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 5
        ))
        let later = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-8",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 8
        ))
        let otherTenant = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-other",
            aggregateID: "conversation-1",
            tenantID: "tenant-b",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 4
        ))
        let store = RecordingIOSNotificationLocalIndexStore(records: [matched, later, otherTenant])
        let center = RecordingIOSNotificationCenter()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        let watermark = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 5
        ))

        let removed = runtime.cancelLocalNotifications(matching: watermark)

        XCTAssertEqual(Set(removed), Set([matched.requestIdentifier, "message-5"]))
        XCTAssertEqual(center.pendingRemovals.map(Set.init), [Set(removed)])
        XCTAssertEqual(center.deliveredRemovals.map(Set.init), [Set(removed)])
        XCTAssertEqual(store.records, [later, otherTenant])
    }

    func testRealtimeLocalNotificationPersistsDeterministicPrivacyMinimalMetadata() throws {
        let metadata = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 7
        ))
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)

        runtime.presentRealtimeMessage(
            eventID: "message-7",
            backgrounded: true,
            localMetadata: metadata
        )

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.identifier, metadata.requestIdentifier)
        XCTAssertEqual(store.records, [metadata])
        XCTAssertEqual(request.content.title, "问达通")
        XCTAssertEqual(request.content.body, "收到新消息通知")
        XCTAssertEqual(request.content.userInfo["channel_seq"] as? String, "7")
        XCTAssertNil(request.content.userInfo["body"])
        XCTAssertNil(request.content.userInfo["sender_name"])
        XCTAssertNil(request.content.userInfo["source_device"])
    }

    func testRealtimeLocalNotificationTapEmitsConversationOpenPayloadFromMetadata() throws {
        let metadata = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 7
        ))
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }

        runtime.presentRealtimeMessage(
            eventID: "message-7",
            backgrounded: true,
            localMetadata: metadata
        )

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.content.userInfo["schema_version"] as? String, "notification_local.v1")
        XCTAssertTrue(runtime.handleNotificationResponse(request.content.userInfo))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened from realtime local notification tap")
        }
        XCTAssertEqual(opened.category, "message")
        XCTAssertEqual(opened.channelID, "c1")
        XCTAssertEqual(opened.channelType, "direct")
        XCTAssertEqual(opened.channelSeq, 7)
        XCTAssertEqual(opened.scopeKey, IOSNotificationRuntime.scopeKey(tenantID: "tenant-a"))
        XCTAssertEqual(opened.targetRef, "")
    }

    func testBackgroundLocalNotificationTapPreservesConversationOpenPayload() throws {
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "message-background-tap-1",
            "aggregate_id": "conversation-background-tap-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-a"),
            "target_ref": "opaque-target-ref-1",
            "tenant_id": "tenant-a",
            "im_uid": "user-a",
            "app_id": "app-ios",
            "channel_id": "conversation-background-tap-1",
            "channel_type": "direct",
            "channel_seq": "11"
        ]

        XCTAssertEqual(
            runtime.handleRemoteNotification(payload, processState: .backgroundAlive),
            .localSystemNotification
        )
        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.content.userInfo["schema_version"] as? String, "notification_state.v1")
        XCTAssertEqual(request.content.userInfo["target_ref"] as? String, "opaque-target-ref-1")
        XCTAssertEqual(request.content.userInfo["channel_seq"] as? String, "11")

        XCTAssertTrue(runtime.handleNotificationResponse(request.content.userInfo))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened from local notification tap")
        }
        XCTAssertEqual(opened.targetRef, "opaque-target-ref-1")
        XCTAssertEqual(opened.channelID, "conversation-background-tap-1")
        XCTAssertEqual(opened.channelSeq, 11)
    }

    func testStandardAPNsRegistrationPreservesRenamedBundleIdentity() {
        let registration = RemoteDeviceRegistration.apns(
            token: "opaque-token",
            bundleID: "com.jianhuitongqiyetest.app",
            environment: "sandbox"
        )
        XCTAssertEqual(registration.pushTokenType, "apns")
        XCTAssertEqual(registration.bundleID, "com.jianhuitongqiyetest.app")
        XCTAssertEqual(registration.requestBody["push_token_type"] as? String, "apns")
    }

    func testPushTokenInvalidationDoesNotDeleteSharedDeviceRowAndScopeRetirementIsSerialized() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appSourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM")
        let appState = try String(
            contentsOf: appSourceRoot.appendingPathComponent("AppState.swift"),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: appSourceRoot.appendingPathComponent("BlueStoneIMApp.swift"),
            encoding: .utf8
        )

        let voipInvalidation = try XCTUnwrap(
            appState.range(of: "case .voipTokenInvalidated:")
                .flatMap { start in
                    appState.range(of: "case let .voipPushPayload", range: start.upperBound..<appState.endIndex)
                        .map { appState[start.lowerBound..<$0.lowerBound] }
                }
        )
        XCTAssertTrue(voipInvalidation.contains("resetVoIPPushRegistrationKeys"))
        XCTAssertTrue(voipInvalidation.contains("retireRegisteredPushTokenSlotIfPossible"))
        XCTAssertFalse(voipInvalidation.contains("disableDevice"))
        XCTAssertFalse(voipInvalidation.contains("retirePushDevices"))

        let standardInvalidation = try XCTUnwrap(
            appState.range(of: "case let .standardRegistrationInvalidated(registration):")
                .flatMap { start in
                    appState.range(of: "case let .notificationOpened", range: start.upperBound..<appState.endIndex)
                        .map { appState[start.lowerBound..<$0.lowerBound] }
                }
        )
        XCTAssertTrue(standardInvalidation.contains("resetStandardPushRegistrationKeys"))
        XCTAssertTrue(standardInvalidation.contains("retireRegisteredPushTokenSlotIfPossible"))
        XCTAssertFalse(standardInvalidation.contains("disableDevice"))
        XCTAssertFalse(standardInvalidation.contains("retirePushDevices"))

        XCTAssertTrue(appState.contains("await retirementTask?.value"))
        XCTAssertTrue(appState.contains("await previousRegistrationTask?.value"))
        XCTAssertTrue(appState.contains("await standardRegistration?.value"))
        XCTAssertTrue(appState.contains("await voipRegistration?.value"))
        XCTAssertTrue(appState.contains("retirePushTokenWithTransientRetry"))
        XCTAssertTrue(appState.contains("provider: .apnsVoIP"))
        XCTAssertFalse(appState.contains("for deviceID in deviceIDs.union(lateStandardDeviceIDs).union(lateVoIPDeviceIDs)"))
        XCTAssertTrue(appDelegate.contains("CallKitPushVoiceCallManager.shared.start()"))
        XCTAssertTrue(appDelegate.contains("didFinishLaunchingWithOptions"))
    }

    func testAPNsEnvironmentUsesSignedConfigurationBeforeBuildFallback() {
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "development", debugFallback: false), "sandbox")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "production", debugFallback: true), "production")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "", debugFallback: true), "sandbox")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: nil, debugFallback: false), "production")
    }

    func testNotificationBadgeCountClampsNegativeStateToZero() {
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(-3), 0)
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(0), 0)
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(101), 101)
    }

    func testStandardTokenInvalidationCarriesTheExactRetiredToken() throws {
        let runtime = IOSNotificationRuntime()
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }

        runtime.updateStandardToken(Data([0x01, 0x02, 0xA0]))
        runtime.invalidateStandardToken()

        guard case let .standardRegistrationInvalidated(registration) = try XCTUnwrap(received.last) else {
            return XCTFail("expected exact invalidated standard registration")
        }
        XCTAssertEqual(registration.pushToken, "0102a0")
        XCTAssertEqual(registration.tokenFingerprint?.count, 64)
        XCTAssertNil(runtime.standardRegistration)
    }

    func testNotificationOpenIsDeliveredIndependentlyFromPresentationDedup() throws {
        let runtime = IOSNotificationRuntime()
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "message-open-42",
            "aggregate_id": "message-open-42",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        ]

        XCTAssertTrue(runtime.accept(eventID: "message-open-42"))
        XCTAssertTrue(runtime.handleNotificationResponse(payload))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened")
        }
        XCTAssertEqual(opened.aggregateID, "message-open-42")
    }

    func testColdNotificationOpenSurvivesMissingAndStaleObserversUntilLiveConsumerBinds() throws {
        let runtime = IOSNotificationRuntime()
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "cold-open-1",
            "aggregate_id": "conversation-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        ]

        XCTAssertTrue(runtime.handleNotificationResponse(payload))
        let staleObserver = runtime.observe { _ in false }
        runtime.removeObserver(staleObserver)

        var received: [IOSNotificationRuntimeEvent] = []
        let liveObserver = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(liveObserver) }

        XCTAssertEqual(received.count, 1)
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.first) else {
            return XCTFail("expected notificationOpened")
        }
        XCTAssertEqual(opened.aggregateID, "conversation-1")
    }

    func testNotificationScopeMatchesServerSHA256PrefixContract() {
        XCTAssertEqual(IOSNotificationRuntime.scopeKey(tenantID: "tenant-42").count, 24)
        XCTAssertEqual(
            IOSNotificationRuntime.scopeKey(tenantID: " tenant-42 "),
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        )
        XCTAssertNotEqual(
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-42"),
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-43")
        )
    }

    func testForegroundStateAcceptsExactEventOnlyOnceForOneSound() {
        let eventID = "notification-state-sound-once"
        XCTAssertTrue(IOSNotificationRuntime.shared.accept(eventID: eventID))
        XCTAssertFalse(IOSNotificationRuntime.shared.accept(eventID: eventID))
    }

    func testRTCCallEventCarriesExactNotificationAckIdentity() throws {
        let event = try JSONDecoder().decode(
            RemoteRTCCallEvent.self,
            from: Data(#"{"id":"event-7","notification_id":"rtc_call:call-7:1:ringing","event":"rtc.call.ringing"}"#.utf8)
        )
        XCTAssertEqual(event.notificationID, "rtc_call:call-7:1:ringing")
    }
}

@MainActor
private final class RecordingIOSNotificationCenter: IOSNotificationCenterManaging {
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var pendingRemovals: [[String]] = []
    private(set) var deliveredRemovals: [[String]] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pendingRemovals.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredRemovals.append(identifiers)
    }
}

@MainActor
private final class RecordingNotificationAuthorizationManager: IOSNotificationAuthorizationManaging {
    var status: IOSNotificationAuthorizationStatus
    var statusAfterRequest: IOSNotificationAuthorizationStatus?
    private(set) var requestCount = 0
    private(set) var registrationCount = 0

    init(status: IOSNotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> IOSNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if let statusAfterRequest {
            status = statusAfterRequest
        }
        return status.permitsRemoteNotificationRegistration
    }

    func registerForRemoteNotifications() {
        registrationCount += 1
    }
}

@MainActor
private final class RecordingIOSNotificationLocalIndexStore: IOSNotificationLocalIndexStoring {
    var records: [IOSNotificationLocalMetadata]

    init(records: [IOSNotificationLocalMetadata] = []) {
        self.records = records
    }

    func loadRecords() -> [IOSNotificationLocalMetadata] {
        records
    }

    func saveRecords(_ records: [IOSNotificationLocalMetadata]) {
        self.records = records
    }
}
