import Foundation
import XCTest
@testable import BlueStoneIM

final class GroupMuteModeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_774_922_400)
    private let end = Date(timeIntervalSince1970: 1_774_951_200)

    func testGroupMuteBannerDecisionShowsOnlyAuthoritativeCurrentMute() {
        var group = memberGroup()
        group.allMuted = true
        group.allMuteMode = .scheduled
        group.allMuteStart = start
        group.allMuteEnd = end
        group.allMuteServerTime = start.addingTimeInterval(-3_600)
        group.allMuteNextBoundary = start
        group.allMuteActive = false

        XCTAssertNil(GroupMuteBannerDecision.resolve(group: group, canManage: false))

        group.allMuteServerTime = end.addingTimeInterval(3_600)
        group.allMuteNextBoundary = nil
        XCTAssertNil(GroupMuteBannerDecision.resolve(group: group, canManage: false))

        group.allMuteActive = true
        let activeMember = GroupMuteBannerDecision.resolve(group: group, canManage: false)
        XCTAssertEqual(activeMember?.title, "当前全员禁言")
        XCTAssertEqual(activeMember?.detail, "当前全员禁言，普通成员暂不可发言。")
        XCTAssertFalse(activeMember?.isRepairRequired ?? true)

        let activeAdmin = GroupMuteBannerDecision.resolve(group: group, canManage: true)
        XCTAssertEqual(activeAdmin?.detail, "当前全员禁言，管理员可发言。")
    }

    func testGroupMuteBannerDecisionDoesNotInferVisibilityFromLocalDateOrTimezone() {
        var group = memberGroup()
        group.allMuted = true
        group.allMuteMode = .scheduled
        group.allMuteStart = Date(timeIntervalSince1970: 1_781_575_400)
        group.allMuteEnd = Date(timeIntervalSince1970: 1_781_579_000)
        group.allMuteServerTime = Date(timeIntervalSince1970: 1_781_571_800)
        group.allMuteNextBoundary = group.allMuteStart
        group.allMuteActive = false

        let originalTimeZone = NSTimeZone.default
        defer { NSTimeZone.default = originalTimeZone }
        for identifier in ["Pacific/Kiritimati", "America/Adak", "Asia/Bangkok"] {
            NSTimeZone.default = try! XCTUnwrap(TimeZone(identifier: identifier))
            XCTAssertNil(
                GroupMuteBannerDecision.resolve(group: group, canManage: false),
                "future scheduled mute must stay hidden in \(identifier)"
            )
        }

        group.allMuteStart = Date(timeIntervalSince1970: 1_781_658_600)
        group.allMuteEnd = Date(timeIntervalSince1970: 1_781_662_200)
        group.allMuteServerTime = Date(timeIntervalSince1970: 1_781_660_400)
        group.allMuteNextBoundary = group.allMuteEnd
        group.allMuteActive = true
        for identifier in ["Pacific/Kiritimati", "America/Adak", "Asia/Bangkok"] {
            NSTimeZone.default = try! XCTUnwrap(TimeZone(identifier: identifier))
            XCTAssertNotNil(
                GroupMuteBannerDecision.resolve(group: group, canManage: false),
                "cross-midnight active mute must stay visible in \(identifier)"
            )
        }
    }

    func testGroupMuteBannerDecisionTracksBoundaryAuthorityWithoutFrozenServerTimeGuessing() {
        var group = memberGroup()
        group.allMuted = true
        group.allMuteMode = .scheduled
        group.allMuteStart = start
        group.allMuteEnd = end
        group.allMuteServerTime = start.addingTimeInterval(-60)
        group.allMuteNextBoundary = start
        group.allMuteActive = false

        XCTAssertNil(GroupMuteBannerDecision.resolve(group: group, canManage: false))

        group.allMuteActive = true
        group.allMuteServerTime = start
        group.allMuteNextBoundary = end
        XCTAssertNotNil(GroupMuteBannerDecision.resolve(group: group, canManage: false))

        group.allMuteActive = false
        group.allMuteServerTime = end
        group.allMuteNextBoundary = nil
        XCTAssertNil(GroupMuteBannerDecision.resolve(group: group, canManage: false))
    }

    func testGroupMuteBannerDecisionKeepsRepairFailClosedAndLegacyAlwaysVisible() {
        var repair = memberGroup()
        repair.allMuted = true
        repair.allMuteMode = .scheduled
        repair.allMuteActive = false
        repair.allMuteRepairRequired = true

        let repairMember = GroupMuteBannerDecision.resolve(group: repair, canManage: false)
        XCTAssertEqual(repairMember?.title, "禁言状态需要管理员修复")
        XCTAssertEqual(repairMember?.detail, "禁言状态需要管理员修复；修复前普通成员无法发送。")
        XCTAssertTrue(repairMember?.isRepairRequired ?? false)

        let repairAdmin = GroupMuteBannerDecision.resolve(group: repair, canManage: true)
        XCTAssertEqual(repairAdmin?.detail, "禁言状态需要修复；修复前群主和管理员可继续发言。")

        var legacyAlways = memberGroup()
        legacyAlways.allMuted = true
        legacyAlways.allMuteMode = nil
        legacyAlways.allMuteActive = nil
        legacyAlways.allMuteStart = nil
        legacyAlways.allMuteEnd = nil
        XCTAssertNotNil(GroupMuteBannerDecision.resolve(group: legacyAlways, canManage: false))

        legacyAlways.allMuteActive = false
        XCTAssertNil(GroupMuteBannerDecision.resolve(group: legacyAlways, canManage: false))

        legacyAlways.allMuted = false
        legacyAlways.allMuteRepairRequired = true
        XCTAssertNil(GroupMuteBannerDecision.resolve(group: legacyAlways, canManage: false))
    }

    func testChatDisabledBannerDecisionDeduplicatesActiveRepairAndLegacyTransitions() {
        func composition(
            _ group: GroupInfo,
            canManage: Bool,
            composerIsDisabled: Bool
        ) -> ChatDisabledBannerDecision {
            ChatDisabledBannerDecision.resolve(
                groupMuteBanner: GroupMuteBannerDecision.resolve(
                    group: group,
                    canManage: canManage
                ),
                composerIsDisabled: composerIsDisabled
            )
        }

        var scheduled = memberGroup()
        scheduled.allMuted = true
        scheduled.allMuteMode = .scheduled
        scheduled.allMuteStart = start
        scheduled.allMuteEnd = end
        scheduled.allMuteServerTime = start.addingTimeInterval(-60)
        scheduled.allMuteNextBoundary = start
        scheduled.allMuteActive = false

        let future = composition(scheduled, canManage: false, composerIsDisabled: false)
        XCTAssertEqual(future.visibleBannerCount, 0)
        XCTAssertFalse(future.showsComposerDisabledNotice)

        scheduled.allMuteServerTime = start
        scheduled.allMuteNextBoundary = end
        scheduled.allMuteActive = true
        let activeMember = composition(scheduled, canManage: false, composerIsDisabled: true)
        XCTAssertEqual(activeMember.visibleBannerCount, 1)
        XCTAssertNotNil(activeMember.groupMuteBanner)
        XCTAssertFalse(activeMember.showsComposerDisabledNotice)

        let activeAdmin = composition(scheduled, canManage: true, composerIsDisabled: false)
        XCTAssertEqual(activeAdmin.visibleBannerCount, 1)
        XCTAssertEqual(activeAdmin.groupMuteBanner?.detail, "当前全员禁言，管理员可发言。")

        scheduled.allMuteServerTime = end
        scheduled.allMuteNextBoundary = nil
        scheduled.allMuteActive = false
        let ended = composition(scheduled, canManage: false, composerIsDisabled: false)
        XCTAssertEqual(ended.visibleBannerCount, 0)

        var repair = scheduled
        repair.allMuteRepairRequired = true
        let repairMember = composition(repair, canManage: false, composerIsDisabled: true)
        XCTAssertEqual(repairMember.visibleBannerCount, 1)
        XCTAssertTrue(repairMember.groupMuteBanner?.isRepairRequired ?? false)
        XCTAssertFalse(repairMember.showsComposerDisabledNotice)

        let repairAdmin = composition(repair, canManage: true, composerIsDisabled: false)
        XCTAssertEqual(repairAdmin.visibleBannerCount, 1)
        XCTAssertTrue(repairAdmin.groupMuteBanner?.isRepairRequired ?? false)

        var legacy = memberGroup()
        legacy.allMuted = true
        legacy.allMuteMode = nil
        legacy.allMuteActive = nil
        legacy.allMuteStart = nil
        legacy.allMuteEnd = nil
        let legacyMember = composition(legacy, canManage: false, composerIsDisabled: true)
        XCTAssertEqual(legacyMember.visibleBannerCount, 1)
        XCTAssertFalse(legacyMember.showsComposerDisabledNotice)

        let genericDisabled = ChatDisabledBannerDecision.resolve(
            groupMuteBanner: nil,
            composerIsDisabled: true
        )
        XCTAssertEqual(genericDisabled.visibleBannerCount, 1)
        XCTAssertTrue(genericDisabled.showsComposerDisabledNotice)

        XCTAssertEqual(
            [future, activeMember, ended].map(\.visibleBannerCount),
            [0, 1, 0],
            "future → active → ended must never leave two visible mute banners"
        )
        XCTAssertTrue(
            [future, activeMember, activeAdmin, ended, repairMember, repairAdmin, legacyMember, genericDisabled]
                .allSatisfy { $0.visibleBannerCount <= 1 }
        )
    }

    func testPersonalGroupDNDProjectionUsesTheGroupSnapshotAcrossAllSurfaces() {
        var group = memberGroup()
        group.muted = false
        var conversation = Conversation(
            id: group.id,
            title: group.name,
            subtitle: "",
            kind: .group,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: true,
            memberCount: 2,
            accentHex: 0,
            participants: [],
            messages: []
        )

        XCTAssertFalse(GroupNotificationMuteProjection.isMuted(group: group, conversation: conversation))

        conversation.isMuted = false
        group.muted = true
        XCTAssertTrue(GroupNotificationMuteProjection.isMuted(group: group, conversation: conversation))
        XCTAssertTrue(GroupNotificationMuteProjection.isMuted(group: group, conversation: nil))
    }

    func testMuteListAccessModeProvidesPermissionSurfaceWithoutRemoteLoading() {
        let manager = GroupMuteListAccessMode(canManage: true)
        XCTAssertEqual(manager, .manage)
        XCTAssertTrue(manager.loadsRemoteList)

        let ordinaryMember = GroupMuteListAccessMode(canManage: false)
        XCTAssertEqual(ordinaryMember, .permissionReadOnly)
        XCTAssertFalse(ordinaryMember.loadsRemoteList)
    }

    func testCanonicalAndLegacyMapping() throws {
        XCTAssertEqual(
            try GroupMuteModeState.normalize(.init(allMuted: false)).mode,
            .off
        )
        XCTAssertEqual(
            try GroupMuteModeState.normalize(.init(allMuted: true)).mode,
            .always
        )
        XCTAssertEqual(
            try GroupMuteModeState.normalize(
                .init(allMuted: true, startAt: start, endAt: end)
            ).mode,
            .scheduled
        )

        for mode in GroupMuteMode.allCases {
            let intent = canonicalIntent(mode)
            let state = try GroupMuteModeState.normalize(intent)
            XCTAssertEqual(state.mode, mode)
            XCTAssertEqual(state.allMuted, mode != .off)
            XCTAssertEqual(state.startAt == nil, mode != .scheduled)
            XCTAssertEqual(state.endAt == nil, mode != .scheduled)
        }
    }

    func testEveryTransitionAndInvalidTargetPreservation() throws {
        for from in GroupMuteMode.allCases {
            let current = try GroupMuteModeState.normalize(canonicalIntent(from))
            for to in GroupMuteMode.allCases {
                let transition = current.transition(to: canonicalIntent(to))
                XCTAssertNil(transition.error, "\(from) -> \(to)")
                XCTAssertEqual(transition.state.mode, to, "\(from) -> \(to)")
            }

            let invalid = current.transition(
                to: .init(
                    allMuted: true,
                    mode: .scheduled,
                    startAt: end,
                    endAt: start
                )
            )
            XCTAssertEqual(invalid.error, .invalidWindow)
            XCTAssertEqual(invalid.state, current)
        }
    }

    func testScheduledBoundariesUseServerTime() throws {
        let state = try GroupMuteModeState.normalize(canonicalIntent(.scheduled))
        let cases: [(Date, Bool, GroupMuteLifecycle, Date?)] = [
            (start.addingTimeInterval(-0.001), false, .scheduledPending, start),
            (start, true, .scheduledActive, end),
            (start.addingTimeInterval(3_600), true, .scheduledActive, end),
            (end, false, .scheduledEnded, nil),
        ]

        for (serverTime, active, lifecycle, boundary) in cases {
            let projection = try state.projection(atServerTime: serverTime)
            XCTAssertEqual(projection.presentationActive, active)
            XCTAssertEqual(projection.lifecycle, lifecycle)
            XCTAssertEqual(projection.presentationNextBoundaryAt, boundary)
        }
    }

    func testAlwaysPersistsAndInvalidLegacyStateFailsClosed() throws {
        let always = try GroupMuteModeState.normalize(canonicalIntent(.always))
        for serverTime in [
            Date(timeIntervalSince1970: 0),
            start,
            Date(timeIntervalSince1970: 4_939_238_400),
        ] {
            let projection = try always.projection(atServerTime: serverTime)
            XCTAssertTrue(projection.presentationActive)
            XCTAssertNil(projection.presentationNextBoundaryAt)
        }

        let invalid = try GroupMuteModeState.projectPersisted(
            .init(allMuted: true, startAt: start),
            atServerTime: start.addingTimeInterval(-3_600)
        )
        XCTAssertNil(invalid.state)
        XCTAssertEqual(invalid.error, .invalidWindow)
        XCTAssertTrue(invalid.projection.presentationActive)
        XCTAssertTrue(invalid.projection.repairRequired)
        XCTAssertEqual(invalid.projection.lifecycle, .repairRequired)
        XCTAssertNil(invalid.projection.presentationNextBoundaryAt)
    }

    func testContradictionsHaveStableErrors() {
        assertError(
            .invalidMode,
            .init(allMuted: true, modeRawValue: "future")
        )
        assertError(
            .invalidMode,
            .init(allMuted: true, modeRawValue: " always ")
        )
        assertError(
            .badRequest,
            .init(allMuted: true, mode: .off)
        )
        assertError(
            .badRequest,
            .init(allMuted: true, mode: .always, endAt: end)
        )
        assertError(
            .invalidWindow,
            .init(allMuted: true, mode: .scheduled, startAt: start)
        )
        assertError(
            .invalidWindow,
            .init(allMuted: true, mode: .scheduled, startAt: end, endAt: start)
        )
    }

    func testRemoteGroupContractsDecodeServerAuthorityWithoutInventingDates() throws {
        let json = """
        {
          "group_id": "group-task021",
          "name": "群禁言合同",
          "all_muted": true,
          "all_muted_mode": "scheduled",
          "all_muted_start_at": "2026-07-29T08:00:00Z",
          "all_muted_end_at": "2026-07-29T10:00:00Z",
          "all_muted_active": false,
          "all_muted_updated_at": "2026-07-29T06:00:00Z",
          "all_muted_repair_required": false,
          "server_time": "2026-07-29T07:00:00Z",
          "next_boundary_at": "2026-07-29T08:00:00Z"
        }
        """
        let group = try JSONDecoder().decode(RemoteUserGroup.self, from: Data(json.utf8))
        XCTAssertEqual(group.allMutedMode, "scheduled")
        XCTAssertEqual(group.allMutedActive, false)
        XCTAssertEqual(group.allMutedStartAt, "2026-07-29T08:00:00Z")
        XCTAssertEqual(group.allMutedEndAt, "2026-07-29T10:00:00Z")
        XCTAssertEqual(group.allMutedUpdatedAt, "2026-07-29T06:00:00Z")
        XCTAssertFalse(group.allMutedRepairRequired)
        XCTAssertEqual(group.serverTime, "2026-07-29T07:00:00Z")
        XCTAssertEqual(group.nextBoundaryAt, "2026-07-29T08:00:00Z")

        let settings = try JSONDecoder().decode(RemoteGroupSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.allMutedMode, "scheduled")
        XCTAssertEqual(settings.allMutedActive, false)
        XCTAssertEqual(settings.serverTime, "2026-07-29T07:00:00Z")
        XCTAssertEqual(settings.nextBoundaryAt, "2026-07-29T08:00:00Z")

        let legacy = try JSONDecoder().decode(
            RemoteGroupSettings.self,
            from: Data(#"{"all_muted":true}"#.utf8)
        )
        XCTAssertTrue(legacy.allMuted)
        XCTAssertEqual(legacy.allMutedMode, "")
        XCTAssertNil(legacy.allMutedActive)
        XCTAssertNil(legacy.allMutedStartAt)
        XCTAssertNil(legacy.allMutedEndAt)
    }

    func testGroupInfoConsumesServerActiveAndUsesExclusiveLegacyEnd() {
        var group = GroupInfo(
            id: "group-task021",
            name: "群禁言合同",
            notice: "",
            owner: "群主",
            members: [],
            admins: [],
            muted: false,
            allMuted: true,
            allMuteStart: start,
            allMuteEnd: end
        )
        XCTAssertFalse(group.isAllMuteActive(at: end))

        group.allMuteMode = .scheduled
        group.allMuteActive = false
        group.allMuteServerTime = start.addingTimeInterval(-60)
        group.allMuteNextBoundary = start
        XCTAssertFalse(group.isAllMuteActive(at: start.addingTimeInterval(60)))
        XCTAssertTrue(group.allMuteStatusText(at: start.addingTimeInterval(60)).hasPrefix("待生效"))

        group.allMuteMode = .always
        group.allMuteActive = true
        group.allMuteStart = nil
        group.allMuteEnd = nil
        group.allMuteNextBoundary = nil
        XCTAssertTrue(group.isAllMuteActive(at: Date.distantFuture))
        XCTAssertEqual(group.allMuteStatusText(), "一直禁言中")
    }

    @MainActor
    func testSendGuardUsesServerActiveAndFailsClosedWhenAuthorityIsMissing() {
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [successResponse("{}")])),
            apiContextOverride: makeContext()
        )
        state.isAuthenticated = true
        var group = memberGroup()
        group.allMuted = true
        group.allMuteMode = .scheduled
        group.allMuteStart = Date.distantFuture
        group.allMuteEnd = Date.distantFuture.addingTimeInterval(3_600)
        group.allMuteActive = nil
        XCTAssertFalse(state.canCurrentUserSend(in: group, at: Date.distantPast))

        group.allMuteActive = false
        XCTAssertTrue(state.canCurrentUserSend(in: group, at: Date.distantFuture))

        group.allMuteActive = true
        XCTAssertFalse(state.canCurrentUserSend(in: group, at: Date.distantPast))

        group.myRole = "owner"
        XCTAssertTrue(state.canCurrentUserSend(in: group, at: Date.distantPast))
    }

    @MainActor
    func testCanonicalHTTPMutationsCarryExplicitModeAndWindowShape() async throws {
        let transport = FakeHTTPTransport(results: [
            successResponse(#"{"group_id":"group-task021"}"#),
            groupDetailResponse(mode: .off),
            successResponse(#"{"group_id":"group-task021"}"#),
            groupDetailResponse(mode: .always),
            successResponse(#"{"group_id":"group-task021"}"#),
            groupDetailResponse(mode: .scheduled)
        ])
        let client = makeClient(transport: transport)
        let context = makeContext()

        _ = try await client.updateGroupMute(
            context: context,
            groupID: "group-task021",
            mode: .off,
            startAt: nil,
            endAt: nil
        )
        _ = try await client.updateGroupMute(
            context: context,
            groupID: "group-task021",
            mode: .always,
            startAt: nil,
            endAt: nil
        )
        _ = try await client.updateGroupMute(
            context: context,
            groupID: "group-task021",
            mode: .scheduled,
            startAt: start,
            endAt: end
        )

        let patches = transport.requests().filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(patches.count, 3)
        let off = try requestBody(patches[0])
        XCTAssertEqual(off["all_muted_mode"] as? String, "off")
        XCTAssertEqual(off["all_muted"] as? Bool, false)
        XCTAssertNil(off["all_muted_start_at"])
        XCTAssertNil(off["all_muted_end_at"])

        let always = try requestBody(patches[1])
        XCTAssertEqual(always["all_muted_mode"] as? String, "always")
        XCTAssertEqual(always["all_muted"] as? Bool, true)
        XCTAssertNil(always["all_muted_start_at"])
        XCTAssertNil(always["all_muted_end_at"])

        let scheduled = try requestBody(patches[2])
        XCTAssertEqual(scheduled["all_muted_mode"] as? String, "scheduled")
        XCTAssertEqual(scheduled["all_muted"] as? Bool, true)
        XCTAssertNotNil(scheduled["all_muted_start_at"])
        XCTAssertNotNil(scheduled["all_muted_end_at"])
    }

    @MainActor
    func testRealtimeAuthorityRejectsStaleEventsAndRepairFailsClosed() {
        let state = AppState(
            api: makeClient(transport: FakeHTTPTransport(results: [successResponse("{}")])),
            apiContextOverride: makeContext()
        )
        state.isAuthenticated = true
        state.groups = [memberGroup()]

        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: 20,
            settings: [
                "all_muted": .bool(true),
                "all_muted_mode": .string("scheduled"),
                "all_muted_active": .bool(false),
                "all_muted_start_at": .string("2030-07-29T08:00:00Z"),
                "all_muted_end_at": .string("2030-07-29T10:00:00Z"),
                "all_muted_repair_required": .bool(false),
                "all_muted_updated_at": .string("2030-07-29T07:00:00Z"),
                "server_time": .string("2030-07-29T07:00:00Z"),
                "next_boundary_at": .string("2030-07-29T08:00:00Z")
            ]
        ))

        var group = try! XCTUnwrap(state.group(id: "group-task021"))
        XCTAssertEqual(group.allMuteMode, .scheduled)
        XCTAssertEqual(group.allMuteActive, false)
        XCTAssertTrue(state.canCurrentUserSend(in: group, at: Date.distantFuture))

        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: nil,
            settings: [
                "all_muted": .bool(true),
                "all_muted_mode": .string("always"),
                "all_muted_active": .bool(true),
                "all_muted_repair_required": .bool(false),
                "all_muted_updated_at": .string("2030-07-29T07:01:00Z"),
                "server_time": .string("2030-07-29T07:01:00Z")
            ]
        ))
        group = try! XCTUnwrap(state.group(id: "group-task021"))
        XCTAssertEqual(group.allMuteMode, .always)
        XCTAssertEqual(group.allMuteActive, true)

        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: nil,
            settings: [
                "all_muted": .bool(false),
                "all_muted_mode": .string("off"),
                "all_muted_active": .bool(false),
                "all_muted_repair_required": .bool(false),
                "all_muted_updated_at": .string("2030-07-29T06:59:00Z"),
                "server_time": .string("2030-07-29T07:01:30Z")
            ]
        ))
        group = try! XCTUnwrap(state.group(id: "group-task021"))
        XCTAssertEqual(group.allMuteMode, .always)
        XCTAssertEqual(group.allMuteActive, true)

        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: nil,
            settings: [
                "all_muted": .bool(false),
                "all_muted_mode": .string("off"),
                "all_muted_active": .bool(false),
                "all_muted_repair_required": .bool(false),
                "all_muted_updated_at": .string("not-rfc3339"),
                "server_time": .string("2030-07-29T07:01:45Z")
            ]
        ))
        group = try! XCTUnwrap(state.group(id: "group-task021"))
        XCTAssertEqual(group.allMuteMode, .always)
        XCTAssertEqual(group.allMuteActive, true)

        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: 21,
            settings: [
                "all_muted": .bool(true),
                "all_muted_mode": .string("scheduled"),
                "all_muted_active": .bool(false),
                "all_muted_start_at": .string("2030-07-29T08:00:00Z"),
                "all_muted_repair_required": .bool(true),
                "all_muted_updated_at": .string("2030-07-29T07:02:00Z"),
                "server_time": .string("2030-07-29T07:02:00Z")
            ]
        ))
        group = try! XCTUnwrap(state.group(id: "group-task021"))
        XCTAssertTrue(group.allMuteRepairRequired)
        XCTAssertEqual(group.allMuteActive, true)
        XCTAssertFalse(state.canCurrentUserSend(in: group))
    }

    @MainActor
    func testMutationFailureRollsBackOptimisticMode() async {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"invalid_group_mute_mode","message":"invalid"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 422
                )
            ],
            delayNanoseconds: 80_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.isAuthenticated = true
        state.groups = [ownerGroup()]
        let completed = expectation(description: "mutation rolled back")

        XCTAssertTrue(state.configureGroupMute("group-task021", mode: .always) { succeeded in
            XCTAssertFalse(succeeded)
            completed.fulfill()
        })
        XCTAssertEqual(state.group(id: "group-task021")?.allMuteMode, .always)

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(state.group(id: "group-task021")?.allMuteMode, .off)
        XCTAssertEqual(state.group(id: "group-task021")?.allMuted, false)
        XCTAssertFalse(state.isGroupMuteMutating("group-task021"))
    }

    @MainActor
    func testRealtimeEventWinsOverDelayedMutationResponse() async throws {
        let transport = FakeHTTPTransport(
            results: [
                successResponse(#"{"group_id":"group-task021"}"#),
                groupDetailResponse(mode: .always)
            ],
            delayNanoseconds: 100_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.isAuthenticated = true
        state.groups = [ownerGroup()]

        XCTAssertTrue(state.configureGroupMute("group-task021", mode: .always))
        state.debugHandleRealtimeEnvelopeForTesting(groupSettingsEnvelope(
            generation: 30,
            settings: [
                "all_muted": .bool(false),
                "all_muted_mode": .string("off"),
                "all_muted_active": .bool(false),
                "all_muted_repair_required": .bool(false),
                "all_muted_updated_at": .string("2030-07-29T07:03:00Z"),
                "server_time": .string("2030-07-29T07:03:00Z")
            ]
        ))

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(state.group(id: "group-task021")?.allMuteMode, .off)
        XCTAssertEqual(state.group(id: "group-task021")?.allMuteActive, false)
        XCTAssertFalse(state.isGroupMuteMutating("group-task021"))
    }

    private func canonicalIntent(_ mode: GroupMuteMode) -> GroupMuteModeIntent {
        switch mode {
        case .off:
            .init(allMuted: false, mode: .off)
        case .always:
            .init(allMuted: true, mode: .always)
        case .scheduled:
            .init(allMuted: true, mode: .scheduled, startAt: start, endAt: end)
        }
    }

    private func assertError(
        _ expected: GroupMuteModeValidationError,
        _ intent: GroupMuteModeIntent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try GroupMuteModeState.normalize(intent),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? GroupMuteModeValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func makeClient(transport: HTTPTransport) -> IMAPIClient {
        IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
    }

    private func makeContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-task021",
            tenantID: "tenant-task021",
            imUID: "member-task021",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-task021"
        )
    }

    private func memberGroup() -> GroupInfo {
        GroupInfo(
            id: "group-task021",
            name: "群禁言合同",
            notice: "",
            owner: "群主",
            ownerID: "owner-task021",
            members: [],
            admins: [],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            allMuteMode: .off,
            allMuteActive: false,
            myRole: "member"
        )
    }

    private func ownerGroup() -> GroupInfo {
        var group = memberGroup()
        group.myRole = "owner"
        return group
    }

    private func groupSettingsEnvelope(
        generation: Int?,
        settings: [String: JSONValue]
    ) -> RealtimeEnvelope {
        var payload: [String: JSONValue] = [
            "group_id": .string("group-task021"),
            "settings": .object(settings)
        ]
        if let generation {
            payload["generation"] = .int(generation)
        }
        return RealtimeEnvelope(
            type: "group.settings.updated",
            requestID: nil,
            payload: payload
        )
    }

    private func successResponse(_ dataJSON: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":\#(dataJSON)}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    private func groupDetailResponse(mode: GroupMuteMode) -> HTTPTransportResult {
        let allMuted = mode == .off ? "false" : "true"
        let active = mode == .always ? "true" : "false"
        let window = mode == .scheduled
            ? #","all_muted_start_at":"2026-03-31T08:00:00Z","all_muted_end_at":"2026-03-31T16:00:00Z""#
            : ""
        let json = """
        {"ok":true,"data":{
          "group":{"group_id":"group-task021","name":"群禁言合同","my_role":"owner","all_muted":\(allMuted),"all_muted_mode":"\(mode.rawValue)","all_muted_active":\(active)\(window)},
          "settings":{"all_muted":\(allMuted),"all_muted_mode":"\(mode.rawValue)","all_muted_active":\(active),"all_muted_repair_required":false\(window)}
        }}
        """
        return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
    }
}
