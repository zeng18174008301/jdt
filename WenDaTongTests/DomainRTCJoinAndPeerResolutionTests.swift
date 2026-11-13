import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
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
        // WDT_IOS1_RTC_FRIEND_SYNC_FIXTURE_20261112_BEGIN
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext(imUID: "me")
        )
        // WDT_IOS1_RTC_FRIEND_SYNC_FIXTURE_20261112_END
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let currentUser = makeUser(id: "me", name: "Me")
        let peer = makeUser(id: "peer-1", name: "Peer")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        XCTAssertTrue(state.contactStore.beginContactsSync())

        XCTAssertFalse(state.canStartVoiceCall(with: peer))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: peer), "好友关系同步中，请稍后再试")

        state.startOutgoingVoiceCall(to: peer)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "好友关系同步中，请稍后再试")
        state.contactStore.finishContactsSync()
    }

    // WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_BEGIN
    @MainActor
    func testAppStateDisplayUserForVoiceCallResolvesGenericCallerFromDirectConversation() throws {
        let state = AppState(apiContextOverride: TestMessageMemoryScope.context)
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

        state.setCurrentUser(makeUser(id: "WXT00000002", name: "陈星")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.conversationStore.commitConversationSnapshots([direct])

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

        state.setCurrentUser(makeUser(id: "self", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [contact]

        let displayUser = state.displayUserForVoiceCall(callerFromPayload)

        XCTAssertEqual(displayUser.id, "339330")
        XCTAssertEqual(displayUser.name, "美死了")
        XCTAssertEqual(displayUser.avatarURL, "https://example.test/admin11.png")
        XCTAssertEqual(displayUser.avatarVersion, "v11")
        XCTAssertEqual(displayUser.avatarUpdatedAt, "2026-07-01T12:00:00Z")
    }

    // WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_END

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
                    DirectConversationCallPeerResolver.resolve(conversation: conversation.conversation,
                        currentIdentityIDs: [" self "], contacts: contacts, contactLookup: lookup),
                    DirectConversationCallPeerResolver.resolve(conversation: conversation.conversation,
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
        XCTAssertEqual(DirectConversationCallPeerResolver.resolve(conversation: conversation.conversation,
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [staleWebContact, androidPeer]

        XCTAssertEqual(state.directConversationCallPeer(for: conversation)?.id, androidPeer.id)
    }

    @MainActor
    func testListProjectionReusesResolvedPeerWithoutChangingCertificationFallbacks() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let current = makeUser(id: "ios-user", name: "Current")
        let peer = makeUser(id: "peer", name: "Peer")
        state.setCurrentUser(current) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
        state.setCurrentUser(makeUser(id: "ios-user", name: "iOS User")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
            apiContextOverride: makeAuthenticatedAPIContext(imUID: "ios-user")
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
