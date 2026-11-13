import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
@testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
    func testBiometricGrantPublishesOnlyTheMatchingProtectedSurface() async throws {
        let suite = "BlueStoneIMTests.biometric-projection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = makeAuthenticatedAPIContext()
        try BiometricProtectionStore.save(.init(enabled: true, unlockChats: true, previewFiles: true), context: context, defaults: defaults)
        let state = AppState(biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults, apiContextOverride: context)
        var chat: [Bool] = []
        var file: [Bool] = []
        var appUpdates = 0
        let subscriptions = [
            state.protectedAccessUpdates(for: .chat).sink { chat.append($0) },
            state.protectedAccessUpdates(for: .filePreview).sink { file.append($0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        let authorized = await state.authorizeProtectedAccess(.chat)
        XCTAssertTrue(authorized)
        XCTAssertEqual(chat, [false, true])
        XCTAssertEqual(file, [false])
        state.biometricAccessStore.revokeGrants()
        XCTAssertEqual(chat, [false, true, false])
        XCTAssertEqual(file, [false])
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_BEGIN
    func testContactSyncObservesDirectoryAndCallReadinessWithoutAppStateRefresh() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.contactStore
        var directory: [ContactStore.ContactsSyncStatus] = []
        var readiness: [Bool] = []
        var globalUpdates = 0
        let status = store.contactsSyncUpdates.sink { directory.append($0) }
        let calls = store.callRelationshipUpdates(matching: ["peer"]).sink { readiness.append($0.friendRelationsPending) }
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            status.cancel()
            calls.cancel()
            global.cancel()
        }
        XCTAssertTrue(store.beginContactsSync())
        store.markFriendRelationsLoaded()
        XCTAssertEqual(readiness, [true])
        store.finishContactsSync()
        XCTAssertEqual(readiness, [true, false])
        store.setContactsSyncError("通讯录同步失败")
        XCTAssertEqual(directory.map(\.isSyncing), [false, true, false, false])
        XCTAssertEqual(directory.last?.errorMessage, "通讯录同步失败")
        XCTAssertEqual(readiness, [true, false])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
    func testFriendRequestsPublishPageAndMatchingPeerWithoutGlobalRefresh() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.contactStore
        var peerStates: [Bool] = []
        var pages: [ContactStore.FriendRequestsSnapshot] = []
        var globalUpdates = 0
        let peer = store.pendingOutgoingFriendRequestUpdates(identities: ["alias"]).sink { peerStates.append($0) }
        let page = store.friendRequestsUpdates.sink { pages.append($0) }
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            peer.cancel()
            page.cancel()
            global.cancel()
        }

        func request(id: String, userID: String, direction: String = " OUTGOING ") -> FriendRequest {
            FriendRequest(
                id: id, name: "Peer", userID: userID, avatarURL: "", source: "", message: "",
                status: " PENDING ", direction: direction, canRespond: false, accepted: false
            )
        }

        store.friendRequests = [request(id: "other", userID: "other")]
        XCTAssertEqual(peerStates, [false])
        store.friendRequests.append(request(id: "incoming", userID: "alias", direction: "incoming"))
        XCTAssertEqual(peerStates, [false])
        store.friendRequests.append(request(id: "matching", userID: " alias "))
        XCTAssertEqual(peerStates, [false, true])
        XCTAssertEqual(pages.last?.requests.map(\.id), ["other", "incoming", "matching"])

        store.cancellingFriendRequestIDs.insert("matching")
        XCTAssertEqual(pages.last?.isCancelling(" matching "), true)
        XCTAssertEqual(peerStates, [false, true])
        store.friendRequests.removeLast()
        XCTAssertEqual(peerStates, [false, true, false])
        store.cancellingFriendRequestIDs.remove("matching")
        XCTAssertEqual(pages.last?.isCancelling("matching"), false)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
        store.reset()
        XCTAssertTrue(store.friendRequestsSnapshot.requests.isEmpty)
        XCTAssertTrue(store.friendRequestsSnapshot.cancellingIDs.isEmpty)
    }
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END

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

    func testIOSUserPresenceSurfacesContainNoPresenceUIOrPlaceholder() throws { // WDT_IOS1_CORE_CHAT_SOURCE_READERS_20261111_BEGIN
        let iosChatRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = iosChatRoot.appendingPathComponent("WenDaTong", isDirectory: true)
        // WDT_IOS1_REFACTOR_FILES_RTC_VIEWS_20261109_BEGIN
        var forbiddenTokensByFile: [String: [String]] = [
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
            "VideoCallViews.swift": ["badgeColor: IMColor.success"],
            "App/WDTApp.swift": ["presenceSummary", "lastLoginCard", "presenceRow("]
        ]
        for file in [
            "FilesRTCViews.swift",
            "Features/Files/FilesView.swift",
            "Features/Files/FileListSupportViews.swift",
            "Features/Files/FilePreviewViews.swift",
            "Features/Files/QuickLookAndFileShareViews.swift",
            "Features/Files/FilesPreviewCacheAdapter.swift",
            "Features/Files/SystemPreviewLoader.swift",
            "Features/Files/FileVisualPresentation.swift",
            "Features/Calls/RTCCallRecordRow.swift",
            "Features/Calls/CallScreenViews.swift",
        ] {
            forbiddenTokensByFile[file] = [
                "badgeColor: peer.isCancelledUser ? nil : IMColor.success",
                "badgeColor: user.isCancelledUser ? nil : IMColor.success",
                "badgeColor: caller.isCancelledUser ? nil : IMColor.success"
            ]
        }
        // WDT_IOS1_REFACTOR_FILES_RTC_VIEWS_20261109_END
        // WDT_IOS1_REFACTOR_APPLICATION_ENTRY_20261110_BEGIN
        let appTokens = try XCTUnwrap(forbiddenTokensByFile["App/WDTApp.swift"])
        for file in [
            "IOSNotificationModels.swift",
            "IOSNotificationAuthorization.swift",
            "IOSNotificationRuntime.swift",
            "ApplicationPolicyScreens.swift",
            "ApplicationOverlayViews.swift",
            "MainShellView.swift",
        ] {
            forbiddenTokensByFile[file] = appTokens
        }
        forbiddenTokensByFile["VideoCallScreenshotHost.swift"] = try XCTUnwrap(
            forbiddenTokensByFile["VideoCallViews.swift"]
        )
        // WDT_IOS1_REFACTOR_APPLICATION_ENTRY_20261110_END
        // WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109_BEGIN
        for file in [
            "Features/Me/AccountInfoViews.swift",
            "Features/Me/ProfileEditViews.swift",
            "Features/Me/EnterpriseSwitcherView.swift",
            "Features/Me/NotificationSettingsView.swift",
            "Features/Me/SecuritySettingsViews.swift",
            "Features/Me/PhoneBindingFlowView.swift",
            "Features/Me/RealNameVerificationViews.swift",
            "Features/Me/DeviceSessionsView.swift",
            "Features/Me/InboxCenterViews.swift",
        ] {
            forbiddenTokensByFile[file] = ["badgeColor: IMColor.success"]
        }
        // WDT_IOS1_REFACTOR_ME_SETTINGS_VIEWS_20261109_END
        // WDT_IOS1_REFACTOR_CONVERSATION_VIEWS_20261109_BEGIN
        let conversationTokens = try XCTUnwrap(forbiddenTokensByFile["ConversationViews.swift"])
        for file in [
            "Features/Conversations/ConversationListHeaderViews.swift",
            "Features/Conversations/ConversationListMentions.swift",
            "Features/Conversations/ConversationListProjection.swift",
            "Features/Conversations/ConversationListRenderCache.swift",
            "Features/Conversations/ConversationListRows.swift",
            "Features/Conversations/ConversationListSearch.swift",
            "Features/Conversations/ConversationListTime.swift",
            "Features/Conversations/FindUserSheet.swift",
            "Features/Conversations/QuickAddViews.swift",
            "Features/Conversations/RecycledConversationTable.swift",
        ] {
            forbiddenTokensByFile[file] = conversationTokens
        }
        // WDT_IOS1_REFACTOR_CONVERSATION_VIEWS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_SHEETS_20261109_BEGIN
        let chatTokens = try XCTUnwrap(forbiddenTokensByFile["ChatViews.swift"])
        for file in [
            "Features/Chat/ChatConversationSheets.swift",
            "Features/Chat/ChatHistorySearchViews.swift",
            "Features/Chat/MessageActionSheets.swift",
            "Features/Chat/ReactionPickerView.swift",
            "Features/Chat/ReadReceiptSheet.swift",
        // WDT_IOS1_REFACTOR_CHAT_SHEETS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_BEGIN
            "Features/Chat/ChatAttachmentDetail.swift",
            "Features/Chat/ChatAttachmentPreview.swift",
            "Features/Chat/ChatAttachmentSelection.swift",
        // WDT_IOS1_REFACTOR_CHAT_ATTACHMENTS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_BEGIN
            "Features/Chat/ChatComposerInputViews.swift",
            "Features/Chat/ChatVoiceRecordingControllers.swift",
            "Features/Chat/ChatVoiceRecordingViews.swift",
        // WDT_IOS1_REFACTOR_CHAT_VOICE_INPUT_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
            "Features/Chat/ChatComposer.swift",
            "Features/Chat/ChatComposerActions.swift",
            "Features/Chat/ChatComposerPanels.swift",
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
            "Features/Chat/ChatAttachmentThumbnailViews.swift",
            "Features/Chat/ChatBubbleMetadataViews.swift",
            "Features/Chat/ChatBubbleTextViews.swift",
            "Features/Chat/ChatForwardViews.swift",
            "Features/Chat/ChatMediaBubbleViews.swift",
            "Features/Chat/ChatMessageActionViews.swift",
            "Features/Chat/MessageBubble.swift",
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_BEGIN
            "Features/Chat/ChatHistorySupportViews.swift",
            "Features/Chat/ChatIdentityPresentation.swift",
            "Features/Chat/ChatScrollMeasurements.swift",
            "Features/Chat/ChatScrollPolicies.swift",
            "Features/Chat/ChatTimelineProjection.swift",
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_BEGIN
            "Features/Chat/ChatViewAttachmentActions.swift",
            "Features/Chat/ChatViewDiagnostics.swift",
            "Features/Chat/ChatViewHeaderAndStatus.swift",
            "Features/Chat/ChatViewHistory.swift",
            "Features/Chat/ChatViewLayout.swift",
            "Features/Chat/ChatViewNavigation.swift",
            "Features/Chat/ChatViewReadAcknowledgement.swift",
            "Features/Chat/ChatViewRenderCache.swift",
            "Features/Chat/ChatViewReply.swift",
            "Features/Chat/ChatViewScrollPosition.swift",
            "Features/Chat/ChatViewTimeline.swift",
        ] {
            forbiddenTokensByFile[file] = chatTokens
        }
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let contactsTokens = try XCTUnwrap(forbiddenTokensByFile["ContactsViews.swift"])
        for file in [
            "Features/Contacts/ContactAvatarPreview.swift",
            "Features/Contacts/ContactCommonRows.swift",
            "Features/Contacts/ContactDirectoryTable.swift",
            "Features/Contacts/ContactGroupDetail.swift",
            "Features/Contacts/ContactGroupList.swift",
            "Features/Contacts/ContactRelationshipViews.swift",
            "Features/Contacts/ContactSearchViews.swift",
            "Features/Contacts/ContactUserProfile.swift",
            "Features/Contacts/DepartmentManagementSheets.swift",
            "Features/Contacts/GroupHistoryScreenshots.swift",
            "Features/Contacts/GroupMemberManagementViews.swift",
            "Features/Contacts/GroupModerationSettingsViews.swift",
            "Features/Contacts/GroupMuteListViews.swift",
            "Features/Contacts/GroupProfileEditSheets.swift",
            "Features/Contacts/GroupSettingsAndLifecycleSheets.swift",
            "Features/Contacts/GroupSharingViews.swift",
            "Features/Contacts/OrganizationDirectoryViews.swift",
        ] {
            forbiddenTokensByFile[file] = contactsTokens
        }
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
        let featureChat = iosChatRoot.appendingPathComponent("Sources/IM4Features/Chat", isDirectory: true)
        let featureFiles = try FileManager.default.contentsOfDirectory(at: featureChat, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for url in featureFiles + ["ChatAttachmentDetail.swift", "ChatAttachmentPreview.swift"].map({ iosChatRoot.appendingPathComponent("Sources/IM4Features/" + $0) }) {
            let oldPath = "Features/Chat/" + url.lastPathComponent
            if !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent(oldPath).path) { forbiddenTokensByFile.removeValue(forKey: oldPath) }
            let featurePath = "Sources/IM4Features/" + (url.deletingLastPathComponent().lastPathComponent == "Chat" ? "Chat/" : "") + url.lastPathComponent
            forbiddenTokensByFile[featurePath] = chatTokens
        }
        if !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Features/Chat/ChatAttachmentThumbnailViews.swift").path) { forbiddenTokensByFile.removeValue(forKey: "Features/Chat/ChatAttachmentThumbnailViews.swift") }
        for file in ["App/ChatTranscriptLayoutAssembly.swift", "DesignSystem/NavigationGestureInstallers.swift", "DesignSystem/DesignSystemModuleExports.swift", "App/ChatAttachmentThumbnailLoader.swift", "App/ChatAttachmentThumbnailAssembly.swift"] { forbiddenTokensByFile[file] = chatTokens }
        // WDT_IOS1_PRESENCE_SIX_FEATURE_SOURCE_SCAN_20261111_BEGIN
        let mediaTokens = try XCTUnwrap(forbiddenTokensByFile["FilesRTCViews.swift"])
        let featureTokens = [
            "Auth": appTokens,
            "Calls": mediaTokens + (try XCTUnwrap(forbiddenTokensByFile["VideoCallViews.swift"])),
            "Contacts": contactsTokens,
            "Conversations": conversationTokens,
            "Files": mediaTokens,
            "Me": try XCTUnwrap(forbiddenTokensByFile["MeSettingsViews.swift"]),
        ]
        for (feature, tokens) in featureTokens {
            let folder = "Sources/IM4Features/\(feature)"
            let directory = iosChatRoot.appendingPathComponent(folder, isDirectory: true)
            let sourceFiles = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".swift") }
            XCTAssertFalse(sourceFiles.isEmpty, "\(folder) has no Swift sources")
            for file in sourceFiles {
                forbiddenTokensByFile["\(folder)/\(file)"] = tokens
            }
        }
        // WDT_IOS1_PRESENCE_SIX_FEATURE_SOURCE_SCAN_20261111_END
        for (file, forbiddenTokens) in forbiddenTokensByFile {
            var source = try String(contentsOf: (file.hasPrefix("Sources/") ? iosChatRoot : sourceRoot).appendingPathComponent(file), encoding: .utf8)
            // Only the byte-exact legacy compatibility forwarder is a non-UI declaration.
            if file == "DesignSystem/DesignSystemModuleExports.swift" {
                let compatibilityForwarder = "    public static func presenceBadgeColor(for status: String, offlineColor: Color = IMColor.muted) -> Color? {\n        IM4DesignSystem.presenceBadgeColor(for: status, offlineColor: offlineColor)\n    }"
                guard source.components(separatedBy: compatibilityForwarder).count == 2 else { throw NSError(domain: "CorePresenceSourceReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Exact legacy compatibility forwarder changed in \(file)"]) }
                source = source.replacingOccurrences(of: compatibilityForwarder, with: "")
            }
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(file) still contains presence UI token: \(token)")
            }
        }
    } // WDT_IOS1_CORE_CHAT_SOURCE_READERS_20261111_END

    func testPresenceUIHidingPreservesBackgroundRealtimeTerminalSignal() {
        let realtime = DeviceKickRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.isConversationListUserInteracting = true

        state.appDidEnterBackground()

        XCTAssertFalse(state.isConversationListUserInteracting)
        XCTAssertEqual(realtime.disconnectCalls, [false])
    }

    func testRealtimePresenceIsConsumedWithoutProjectingIntoUserModels() {
        let state = AppState(
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
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
}
