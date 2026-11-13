import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
@testable import WenDaTong

extension AvatarRealtimeProjectionTests {
    func testPeriodicAuthorityWithoutEventProjectsAllExactUIDCollections() throws {
        var root = AvatarRealtimeProjection()
        root.bind(tenantID: "tenant-a")
        let outcomes = root.applyAuthorityBatch(
            summaries: [
                try summary(
                    revision: 9,
                    generation: 12,
                    url: "/api/tenant/avatar/authority-new"
                )
            ],
            subjectTenantID: "tenant-a"
        )
        guard case .applied(let projection) = outcomes.first else {
            return XCTFail("periodic authority did not yield an avatar projection")
        }
        let resolvedURL = "https://tenant.example/api/tenant/avatar/authority-new"

        let friend = FriendRequest(
            id: "request-1",
            name: "Friend",
            userID: "u-1",
            avatarURL: "old-friend",
            source: "contacts",
            message: "hello",
            accepted: false
        )
        let join = GroupJoinRequest(
            id: "join-1",
            groupID: "group-1",
            applicantUID: "u-1",
            applicantName: "Applicant",
            applicantAvatarURL: "old-applicant",
            inviterAvatarURL: "keep-inviter",
            inviterName: "Inviter",
            status: "pending",
            message: "join",
            createdAt: "now"
        )
        let call = CallRecord(
            id: "call-1",
            peerID: "u-1",
            peerAvatarURL: "old-call",
            peerAvatarVersion: "8",
            peerAvatarUpdatedAt: "older",
            title: "Call",
            subtitle: "",
            time: "now",
            status: "ended"
        )
        let search = UserSearchResult(
            imUID: "u-1",
            userID: "public-u-1",
            nickname: "Search",
            phone: "",
            avatarURL: "old-search",
            status: "normal",
            presenceStatus: "离开",
            relationStatus: "none",
            canApplyFriend: true,
            reason: ""
        )
        let mute = GroupMuteListItem(
            groupID: "group-1",
            targetUID: "u-1",
            targetUserID: "public-u-1",
            targetUsername: "user-one",
            targetNickname: "Muted",
            targetAvatarURL: "old-mute",
            targetRole: "member",
            operatorUID: "admin-1",
            operatorName: "Admin",
            reason: "spam",
            createdAt: "now",
            updatedAt: "now",
            createdAtText: "now",
            updatedAtText: "now"
        )

        let projectedFriends = [friend].map {
            AvatarRealtimeSurfaceProjector.friendRequest(
                $0,
                projection: projection,
                resolvedURL: resolvedURL
            )
        }
        let projectedJoins = [join].map {
            AvatarRealtimeSurfaceProjector.groupJoinRequest(
                $0,
                projection: projection,
                resolvedURL: resolvedURL
            )
        }
        let projectedCalls = [call].map {
            AvatarRealtimeSurfaceProjector.callRecord(
                $0,
                projection: projection,
                resolvedURL: resolvedURL
            )
        }
        let projectedSearch = AvatarRealtimeSurfaceProjector.userSearchResult(
            search,
            projection: projection,
            resolvedURL: resolvedURL
        )
        let projectedMute = AvatarRealtimeSurfaceProjector.groupMuteListItem(
            mute,
            projection: projection,
            resolvedURL: resolvedURL
        )

        XCTAssertEqual(projectedFriends.first?.avatarURL, resolvedURL)
        XCTAssertEqual(projectedJoins.first?.applicantAvatarURL, resolvedURL)
        XCTAssertEqual(projectedJoins.first?.inviterAvatarURL, "keep-inviter")
        XCTAssertEqual(projectedCalls.first?.peerAvatarURL, resolvedURL)
        XCTAssertEqual(projectedCalls.first?.peerAvatarVersion, "file-fresh")
        XCTAssertEqual(projectedSearch.avatarURL, resolvedURL)
        XCTAssertEqual(projectedSearch.presenceStatus, "离开")
        XCTAssertEqual(projectedMute.targetAvatarURL, resolvedURL)

        let unrelated = FriendRequest(
            id: "request-2",
            name: "Other",
            userID: "u-2",
            avatarURL: "keep-other",
            source: "contacts",
            message: "hello",
            accepted: false
        )
        XCTAssertEqual(
            AvatarRealtimeSurfaceProjector.friendRequest(
                unrelated,
                projection: projection,
                resolvedURL: resolvedURL
            ).avatarURL,
            "keep-other"
        )
    }

    func testDirectRowPeerResolutionRejectsSelfAndSupportsBothCanonicalOrders() {
        XCTAssertFalse(
            AvatarRealtimeSurfaceProjector.isDirectPeerEvent(
                conversationID: "me:peer",
                remoteChannelID: "me:peer",
                participantUIDs: ["me", "peer"],
                currentUID: "me",
                eventUID: "me"
            )
        )
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.isDirectPeerEvent(
                conversationID: "me:peer",
                remoteChannelID: "me:peer",
                participantUIDs: ["me"],
                currentUID: "me",
                eventUID: "peer"
            )
        )
        XCTAssertEqual(
            AvatarRealtimeSurfaceProjector.directPeerUID(
                conversationID: "me:peer",
                remoteChannelID: "me:peer",
                participantUIDs: [],
                currentUID: "me"
            ),
            "peer"
        )
        XCTAssertEqual(
            AvatarRealtimeSurfaceProjector.directPeerUID(
                conversationID: "peer:me",
                remoteChannelID: "peer:me",
                participantUIDs: [],
                currentUID: "me"
            ),
            "peer"
        )
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.isDirectPeerEvent(
                conversationID: "peer:me",
                remoteChannelID: "peer:me",
                participantUIDs: ["peer"],
                currentUID: "me",
                eventUID: "peer"
            )
        )
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.isDirectPeerEvent(
                conversationID: "direct:me:peer",
                remoteChannelID: "direct:peer:me",
                participantUIDs: ["me"],
                currentUID: "me",
                eventUID: "peer"
            )
        )
    }

    func testCallAuthorityUIDPrefersIMUIDOverPublicUserID() {
        let record = CallRecord(
            id: "call-1",
            peerID: "im-peer",
            peerUserID: "public-peer",
            title: "Call",
            subtitle: "",
            time: "now",
            status: "ended"
        )
        XCTAssertEqual(
            AvatarRealtimeSurfaceProjector.authorityUID(for: record),
            "im-peer"
        )
    }

    func testAvatarOnlyAuthorityLoopDoesNotRequireCertificationRootScope() {
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.shouldMaintainAuthorityLoop(
                certificationUIDs: [],
                certificationScopeMatches: false,
                avatarUIDs: ["current-im-uid"]
            )
        )
        XCTAssertFalse(
            AvatarRealtimeSurfaceProjector.shouldMaintainAuthorityLoop(
                certificationUIDs: ["cert-only"],
                certificationScopeMatches: false,
                avatarUIDs: []
            )
        )
    }

    @MainActor
    func testAuthorityAvatarBatchPublishesConversationChangesOnce() {
        let context = IMAPIContext(
            platformToken: "platform-token", accountID: "account-a", tenantID: "tenant-a",
            imUID: "self-a", imToken: "im-token", platformAuthSession: nil,
            tenantAuthSession: nil, appID: IMAPIContext.canonicalIOSAppID, deviceID: "device-a"
        )
        let state = AppState(
            api: IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!
            ),
            voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: context
        )
        let users = (1...48).map { index in
            IMUser(id: "u-\(index)", name: "User \(index)", title: "", department: "",
                   phone: "", email: "", status: "normal", enterprise: "Tenant",
                   avatarSeed: UInt(index), badges: [])
        }
        state.contacts = users
        state.conversationStore.commitConversationSnapshots(users.map { user in
            ConversationMessageSnapshot(id: "self-a:\(user.id)", title: user.name, subtitle: "", kind: .direct,
                         lastMessage: "retained", time: "", unread: 3, isPinned: true,
                         isMuted: false, memberCount: nil, accentHex: 0,
                         participants: [user], messages: [])
        })
        let projections = users.map { user in
            AvatarRealtimeProjectionValue(tenantID: "tenant-a", uid: user.id,
                url: "/api/tenant/avatar/opaque-\(user.id)", cacheVersion: "7",
                updatedAt: "2026-09-09T00:00:00Z", revision: 7, generation: 1)
        }
        var publications = 0
        let subscription = state.conversationStore.memoryUpdates.map { _ in state.conversationStore.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { _ in publications += 1 } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { subscription.cancel() }
        // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
        var searchRevisions: [Int64] = []
        var globalUpdates = 0
        let observers = [
            state.avatarSearchPresentationStore.$revision.dropFirst().sink { searchRevisions.append($0) },
            state.objectWillChange.sink { globalUpdates += 1 }
        ]
        defer { observers.forEach { $0.cancel() } }
        // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END
        let revision = state.avatarRealtimePresentationRevision
        state.debugApplyAvatarRealtimeProjectionsForTesting(projections)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(state.avatarRealtimePresentationRevision, revision + 1)
        XCTAssertTrue(state.contacts.allSatisfy { $0.avatarVersion == "7" })
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().allSatisfy {
            $0.avatarVersion == "7" && $0.participants.first?.avatarVersion == "7"
                && $0.isPinned && $0.unread == 3 && $0.lastMessage == "retained"
        })
        state.debugApplyAvatarRealtimeProjectionsForTesting(projections)
        state.debugApplyAvatarRealtimeProjectionsForTesting([
            AvatarRealtimeProjectionValue(tenantID: "foreign", uid: users[0].id,
                url: "/api/tenant/avatar/foreign", cacheVersion: "99", updatedAt: "",
                revision: 99, generation: 99)
        ])
        XCTAssertEqual(publications, 1, "identical and foreign batches must not publish")
        XCTAssertEqual(state.avatarRealtimePresentationRevision, revision + 1)
        // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
        XCTAssertEqual(searchRevisions, [revision + 1])
        XCTAssertEqual(globalUpdates, 0)
        // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END
    }

    @MainActor
    func testBatchReapplyResolvesEachStoredProjectionOnceAndSkipsIdempotentPublish() {
        let subjectCount = 48
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!
        )
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "self-a",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "device-a"
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: context
        )

        for index in 1...subjectCount {
            let uid = String(format: "u-%03d", index)
            state.debugHandleRealtimeEnvelopeForTesting(
                envelope(
                    uid: uid,
                    revision: Int64(index),
                    generation: Int64(index),
                    url: "/api/tenant/avatar/avatar_opaque-\(index)"
                )
            )
        }
        state.contacts = (1...subjectCount).map { index in
            IMUser(
                id: String(format: "u-%03d", index),
                name: "User (index)",
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "normal",
                enterprise: "Tenant",
                avatarSeed: UInt(index),
                badges: []
            )
        }

        state.debugResetAvatarRealtimeAssetResolutionCountForTesting()
        let presentationRevision = state.avatarRealtimePresentationRevision
        state.debugReapplyAllAvatarRealtimeProjectionsForTesting()

        XCTAssertEqual(
            state.debugAvatarRealtimeAssetResolutionCountForTesting(),
            subjectCount,
            "a batch reapply must resolve each stored projection once, not once per surface item"
        )
        XCTAssertEqual(
            state.avatarRealtimePresentationRevision,
            presentationRevision,
            "an identical batch must not publish a new presentation revision"
        )
        XCTAssertEqual(state.contacts.count, subjectCount)
        XCTAssertTrue(state.contacts.allSatisfy { !$0.avatarURL.isEmpty })
        XCTAssertEqual(state.contacts.last?.avatarVersion, String(subjectCount))
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
