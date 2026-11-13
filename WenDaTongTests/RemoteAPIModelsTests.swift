@testable import IM4Domain
import XCTest
@testable import WenDaTong

final class RemoteAPIModelsTests: XCTestCase {
    // WDT_IOS1_SAFE_NUMERIC_20261023_BEGIN
    private struct NumericEnvelope: Decodable {
        let integer: Int?
        let int64: Int64?
        let string: String?
        let double: Double?
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            integer = c.decodeLossyIntIfPresent(forKey: .value)
            int64 = c.decodeLossyInt64IfPresent(forKey: .value)
            string = c.decodeLossyStringIfPresent(forKey: .value)
            double = c.decodeLossyDoubleIfPresent(forKey: .value)
        }
    }

    func testLossyNumbersRejectUnrepresentableIntegersWithoutTrapping() throws {
        for literal in ["1e100", "-1e100", "9223372036854775808", "-9223372036854777856"] {
            let value = try JSONDecoder().decode(NumericEnvelope.self, from: Data("{\"value\":\(literal)}".utf8))
            XCTAssertNil(value.integer, literal)
            XCTAssertNil(value.int64, literal)
            XCTAssertNotNil(value.string)
        }
        for literal in ["42.75", "-42.75"] {
            let value = try JSONDecoder().decode(NumericEnvelope.self, from: Data("{\"value\":\(literal)}".utf8))
            XCTAssertEqual(value.integer, literal.hasPrefix("-") ? -42 : 42)
        }
        for literal in [String(Int64.max), String(Int64.min)] {
            let value = try JSONDecoder().decode(NumericEnvelope.self, from: Data("{\"value\":\(literal)}".utf8))
            XCTAssertEqual(value.int64, Int64(literal))
            XCTAssertEqual(value.string, literal)
        }
        for literal in ["nan", "inf", "-inf", "1e999"] {
            let data = try JSONSerialization.data(withJSONObject: ["value": literal])
            XCTAssertNil(try JSONDecoder().decode(NumericEnvelope.self, from: data).double)
        }
    }

    func testPayloadNumericBoundariesKeepValidAliasesAndWaveformSamples() {
        for invalid in [Double.nan, .infinity, -.infinity, 1e100, -1e100, Double(Int64.max)] {
            let payload: [String: JSONValue] = ["bad": .double(invalid), "valid": .int(17)]
            XCTAssertEqual(RemotePayloadReader.int64(payload, ["bad", "valid"]), 17)
        }
        XCTAssertNil(RemotePayloadReader.double(["v": .string("nan")], ["v"]))
        XCTAssertNil(RemotePayloadReader.double(["v": .double(.infinity)], ["v"]))
        XCTAssertEqual(RemotePayloadReader.intArray(["v": .array([.double(1e100), .double(.nan), .double(2.6), .int(4)])], ["v"]), [3, 4])
        for invalid in [Double.nan, .infinity, 1e100, -1, 61] {
            XCTAssertNil(VoiceMessagePayload.decodedDurationMS(invalid))
        }
        XCTAssertEqual(VoiceMessagePayload.decodedDurationMS(60), 60_000)
        XCTAssertEqual(VoiceMessagePayload.decodedDurationMS(1.234), 1_234)
    }
    // WDT_IOS1_SAFE_NUMERIC_20261023_END

    // WDT_APP_CONTRACT_20261021: explicit false, unknown and legacy projections stay distinct.
    func testMessageActionsPreferEffectiveAndFailClosedForMalformedValues() throws {
        let decoder = JSONDecoder()
        let policy = try decoder.decode(MessageActionsPolicy.self, from: Data(#"{"message_recall_enabled":true,"message_edit_enabled":true,"message_forward_enabled":false,"message_actions":{"effective":{"recall_enabled":false,"edit_enabled":"true"}}}"#.utf8))
        XCTAssertEqual(policy.recallEnabled, false)
        XCTAssertNil(policy.editEnabled)
        XCTAssertEqual(policy.forwardEnabled, false)
        for json in [#"{}"#, #"{"message_actions":{"effective":null},"message_recall_enabled":true}"#,
                     #"{"message_actions":false,"message_recall_enabled":true}"#] {
            XCTAssertNil(try decoder.decode(MessageActionsPolicy.self, from: Data(json.utf8)).recallEnabled)
        }
        let legacy = try decoder.decode(MessageActionsPolicy.self, from: Data(#"{"message_edit_enabled":true}"#.utf8))
        XCTAssertEqual(legacy.editEnabled, true)
        XCTAssertNil(legacy.forwardEnabled)
    }

    func testInteractionProjectionDoesNotTreatStringsOrAdminAsOrdinaryExemptions() throws {
        let policy = try JSONDecoder().decode(TenantInteractionPolicy.self, from: Data(#"{"group":{"allow_member_group_leave":false},"relationship":{"allow_member_friend_delete":"true","allow_member_blacklist":true},"message":{"processing_notice_enabled":false}}"#.utf8))
        XCTAssertEqual(policy.allowMemberGroupLeave, false)
        XCTAssertNil(policy.allowMemberFriendDelete)
        XCTAssertEqual(policy.allowMemberBlacklist, true)
        XCTAssertEqual(policy.processingNoticeEnabled, false)
        XCTAssertFalse(TenantInteractionPolicy.permitsOrdinaryAction(role: "member", enabled: nil))
        XCTAssertFalse(TenantInteractionPolicy.permitsOrdinaryAction(role: "admin", enabled: true))
        XCTAssertTrue(TenantInteractionPolicy.permitsOrdinaryAction(role: " INTERNAL ", enabled: false))
        XCTAssertTrue(TenantInteractionPolicy.permitsOrdinaryAction(role: "member", enabled: true))
        XCTAssertNil(try JSONDecoder().decode(TenantInteractionPolicy.self, from: Data("{}".utf8)).processingNoticeEnabled)
    }

    func testGroupSummaryPreservesUnknownCountsRoleAndGroupFriendApplyPolicy() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(RemoteGroupSummary.self, from: Data(#"{"group":{"group_id":"g1"}}"#.utf8))
        XCTAssertNil(empty.memberCount)
        XCTAssertNil(empty.counts.adminCount)
        XCTAssertNil(empty.explicitMyRole)
        XCTAssertTrue(empty.memberFriendApplyEnabled)
        let nested = try decoder.decode(RemoteGroupSummary.self, from: Data(#"{"group":{"group_id":"g1","settings":{"web_member_friend_apply_enabled":false}},"my_role":"member","counts":{"admin_count":0}}"#.utf8))
        XCTAssertFalse(nested.memberFriendApplyEnabled)
        XCTAssertEqual(nested.explicitMyRole, "member")
        XCTAssertEqual(nested.counts.adminCount, 0)
        let malformed = try decoder.decode(RemoteGroupSettings.self, from: Data(#"{"web_member_friend_apply_enabled":"true"}"#.utf8))
        XCTAssertFalse(malformed.memberFriendApplyEnabled)
    }

    func testInvitationsDistinguishApprovalAndAlreadyMemberResults() throws {
        let decoder = JSONDecoder()
        let approval = try decoder.decode(RemoteInviteGroupMembersResponse.self, from: Data(#"{"items":[],"status":"pending_approval"}"#.utf8))
        XCTAssertTrue(approval.requiresApproval)
        XCTAssertEqual(approval.invitationResultMessage, "已提交入群邀请，等待审核")
        let existing = try decoder.decode(RemoteInviteGroupMembersResponse.self, from: Data(#"{"items":[],"status":"already_member","already_members":["u1"]}"#.utf8))
        XCTAssertFalse(existing.requiresApproval)
        XCTAssertEqual(existing.invitationResultMessage, "1 人已在群中")
    }

    func testRTCPolicyRejectsPartialInvalidAndUnnegotiatedMedia() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(RemoteRTCMedia.self, from: Data("{}".utf8))
        XCTAssertEqual(try RTCIcePolicy.resolve(legacy.icePolicy, requiresV1: false, servers: []), .legacy)
        XCTAssertThrowsError(try RTCIcePolicy.resolve(legacy.icePolicy, requiresV1: true, servers: []))
        for payload in [
            #"{"ice_transport_policy":null}"#,
            #"{"ice_transport_policy":"relay"}"#,
            #"{"ice_transport_policy_version":1}"#,
            #"{"rtc_config_revision":"r1"}"#,
            #"{"ice_transport_policy":"invalid","ice_transport_policy_version":1,"rtc_config_revision":"r1"}"#,
            #"{"ice_transport_policy":"all","ice_transport_policy_version":"1","rtc_config_revision":"r1"}"#,
            #"{"ice_transport_policy":"all","ice_transport_policy_version":true,"rtc_config_revision":"r1"}"#,
            #"{"ice_transport_policy":"all","ice_transport_policy_version":2,"rtc_config_revision":"r1"}"#,
            #"{"ice_transport_policy":"all","ice_transport_policy_version":1,"rtc_config_revision":" "}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(RemoteRTCMedia.self, from: Data(payload.utf8)))
        }
    }

    func testRTCPolicyKeepsOpaqueRevisionAndRejectsRefreshDowngrade() throws {
        let data = Data(#"{"ice_transport_policy":"relay","ice_transport_policy_version":1,"rtc_config_revision":"9007199254740993"}"#.utf8)
        let value = try JSONDecoder().decode(RemoteRTCMedia.self, from: data).icePolicy!
        XCTAssertEqual(value.revision, "9007199254740993")
        XCTAssertNoThrow(try value.validateReplacement(value))
        XCTAssertThrowsError(try value.validateReplacement(nil))
        XCTAssertThrowsError(try value.validateReplacement(.legacy))
        XCTAssertThrowsError(try value.validateReplacement(RTCIcePolicy(transport: .all, version: 1, revision: value.revision)))
        XCTAssertThrowsError(try value.validateReplacement(RTCIcePolicy(transport: .relay, version: 1, revision: "new")))
    }

    func testRTCRelayRequiresCredentialedTURNWithoutWeakeningAll() throws {
        let relay = RTCIcePolicy(transport: .relay, version: 1, revision: "r1")
        for payload in [
            #"[{"urls":["stun:fixture.invalid:3478"],"username":"fixture","credential":"fixture"}]"#,
            #"[{"urls":["turn:fixture.invalid:3478"]}]"#,
            #"[{"urls":["turn:"],"username":"fixture","credential":"fixture"}]"#
        ] {
            let servers = try JSONDecoder().decode([RemoteRTCIceServer].self, from: Data(payload.utf8))
            XCTAssertThrowsError(try relay.validateServers(servers))
        }
        let servers = try JSONDecoder().decode([RemoteRTCIceServer].self, from: Data(#"[{"urls":["turns:fixture.invalid:5349?transport=tcp"],"username":"fixture","credential":"fixture"}]"#.utf8))
        XCTAssertNoThrow(try relay.validateServers(servers))
        XCTAssertThrowsError(try relay.validateServers([]))
        XCTAssertNoThrow(try RTCIcePolicy.legacy.validateServers([]))
    }

    func testRTCProviderAdvertisementRequiresExactIntegerOne() throws {
        XCTAssertNil(try JSONDecoder().decode(RemoteRTCProvider.self, from: Data("{}".utf8)).iceTransportPolicyVersion)
        XCTAssertEqual(try JSONDecoder().decode(RemoteRTCProvider.self, from: Data(#"{"ice_transport_policy_version":1}"#.utf8)).iceTransportPolicyVersion, 1)
        for value in ["null", "true", "0", "2", "\"1\""] {
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRTCProvider.self, from: Data(("{\"ice_transport_policy_version\":" + value + "}").utf8)))
        }
    }

    @MainActor
    func testConversationPagesPublishBeforeNextRequestAndOnlyFinishAtLastPage() async throws {
        var published = 0
        var requested: [String] = []
        let version = try await ConversationPageLoader.load(request: { cursor in
            requested.append(cursor)
            if cursor.isEmpty {
                return RemoteConversationPage(conversations: [], hasMore: true, nextCursor: "next", snapshotID: "s", snapshotVersion: 7)
            }
            XCTAssertEqual(published, 1)
            return RemoteConversationPage(conversations: [], hasMore: false, nextCursor: nil, snapshotID: "s", snapshotVersion: 7)
        }, validate: {}, onPage: { _ in published += 1 }, onRestart: { XCTFail("Unexpected restart") })
        XCTAssertEqual(requested, ["", "next"])
        XCTAssertEqual(published, 2)
        XCTAssertEqual(version, 7)
    }

    @MainActor
    func testConversationPageFailureKeepsPublishedPageAndBoundsSharedRetryBudget() async throws {
        var requests = 0
        var published = 0
        var delays: [UInt64] = []
        do {
            _ = try await ConversationPageLoader.load(request: { cursor in
                requests += 1
                if cursor.isEmpty {
                    return RemoteConversationPage(conversations: [], hasMore: true, nextCursor: "next", snapshotID: "s", snapshotVersion: 7)
                }
                throw ConversationPageFailure(statusCode: 503, code: "unavailable")
            }, validate: {}, onPage: { _ in published += 1 }, onRestart: { XCTFail("Unexpected restart") }, delay: { delays.append($0) })
            XCTFail("Incomplete snapshot must not succeed")
        } catch { XCTAssertTrue(error is ConversationPageFailure) }
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(delays, [400_000_000, 1_000_000_000])
    }

    @MainActor
    func testConversationCursorExpiryRetiresOldSnapshotAndRestartsOnce() async throws {
        var requests = 0
        var restarts = 0
        var visible: [String] = []
        let version = try await ConversationPageLoader.load(request: { cursor in
            requests += 1
            if requests == 2 { throw ConversationPageFailure(statusCode: 410, code: "conversation_page_cursor_expired") }
            return RemoteConversationPage(conversations: [], hasMore: requests == 1, nextCursor: "next",
                snapshotID: requests == 1 ? "old" : "new", snapshotVersion: requests == 1 ? 7 : 8)
        }, validate: {}, onPage: { visible.append($0.snapshotID!) }, onRestart: {
            restarts += 1
            visible.removeAll()
        })
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(visible, ["new"])
        XCTAssertEqual(version, 8)
        var attempts = 0
        do {
            _ = try await ConversationPageLoader.load(request: { _ in
                attempts += 1
                throw ConversationPageFailure(statusCode: 410, code: "conversation_page_cursor_expired")
            }, validate: {}, onPage: { _ in XCTFail() }, onRestart: {})
            XCTFail("Expiry restart must be bounded")
        } catch { XCTAssertEqual(attempts, 2) }
    }

    @MainActor
    func testConversationLatePageAndInvalidSnapshotNeverPublish() async throws {
        for scenario in ["scope", "snapshot", "cursor"] {
            var current = true
            var requests = 0
            var published = 0
            do {
                _ = try await ConversationPageLoader.load(request: { _ in
                    requests += 1
                    if scenario == "scope" { current = false }
                    return RemoteConversationPage(conversations: [], hasMore: true, nextCursor: "next",
                        snapshotID: scenario == "snapshot" && requests > 1 ? "other" : "s", snapshotVersion: 7)
                }, validate: { if !current { throw CancellationError() } }, onPage: { _ in published += 1 }, onRestart: { XCTFail() })
                XCTFail("Invalid page must fail closed")
            } catch {
                XCTAssertEqual(published, scenario == "scope" ? 0 : 1)
                XCTAssertEqual(requests, scenario == "scope" ? 1 : 2)
            }
        }
    }

    func testConversationPageRequiresExplicitCompletionContract() throws {
        for json in [#"{"conversations":[]}"#, #"{"conversations":[],"has_more":"false"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteConversationPage.self, from: Data(json.utf8)))
        }
        let page = try JSONDecoder().decode(RemoteConversationPage.self,
            from: Data(#"{"conversations":[],"has_more":false,"snapshot_id":"empty"}"#.utf8))
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.snapshotVersion)
    }

    func testGatewayRTCNotificationWakesAuthoritativeSignalingForEveryLifecycleAndMediaType() throws {
        for key in ["type", "kind"] {
            for event in ["ringing", "cancel", "ended", "timeout", "answered_elsewhere"] {
                for media in ["audio", "voice", "video"] {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "type": "notification", "payload": [key: "rtc_call", "event": event,
                        "call_type": media, "call_id": "call-1", "tenant_id": "tenant-1"]
                    ])
                    let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
                    XCTAssertTrue(envelope.isRTCCallNotification)
                    XCTAssertEqual(envelope.type, "notification", "Keep the existing gateway contract")
                    XCTAssertEqual(envelope.payload["event"]?.stringValue, event)
                }
            }
        }
        for json in [
            #"{"type":"notification","payload":{"type":"message","kind":"chat"}}"#,
            #"{"type":"notification","payload":{"event":"ringing","call_id":"call-1"}}"#,
            #"{"type":"message","payload":{"type":"rtc_call"}}"#,
            #"{"type":"rtc_call","payload":{"event":"ringing"}}"#,
            #"{"type":"notification","payload":{}}"#
        ] {
            XCTAssertFalse(try JSONDecoder().decode(RealtimeEnvelope.self, from: Data(json.utf8)).isRTCCallNotification)
        }
    }

    func testFriendRequestSourceLabelsPreserveMessageIdentityAndStatus() throws {
        func projection(source: String, status: String = "pending", direction: String = "incoming",
                        message: String = "profile", groupName: String? = nil) throws -> FriendRequest {
            var payload: [String: Any] = [
                "id": "request-" + status, "applicant_uid": "peer-60", "target_uid": "self-22",
                "applicant_name": "Peer", "target_name": "Self", "source": source,
                "status": status, "direction": direction, "message": message,
                "actionable_by_current_user": status == "pending"
            ]
            if let groupName { payload["source_group_name"] = groupName }
            let remote = try JSONDecoder().decode(RemoteFriendApplication.self,
                from: JSONSerialization.data(withJSONObject: payload))
            return try XCTUnwrap(AppState.friendRequestProjection(remote, currentID: "self-22"))
        }
        for (raw, title) in [("direct_chat_not_friends", "来自私聊"), ("profile", "来自个人资料"),
                             ("search_user", "来自用户搜索"), ("同事介绍", "同事介绍"), ("future_source", "future_source")] {
            let item = try projection(source: raw)
            XCTAssertEqual(item.source, title)
            XCTAssertEqual(item.message, "profile", "A user's message matching a source key must remain untouched")
            XCTAssertEqual(item.userID, "peer-60")
            XCTAssertTrue(item.isPendingIncoming)
            XCTAssertEqual(item.id, "request-pending")
        }
        XCTAssertEqual(try projection(source: "", groupName: "项目群").source, "项目群")
        XCTAssertEqual(try projection(source: "").source, "好友申请")
        let outgoing = try projection(source: "profile", direction: "outgoing")
        XCTAssertEqual(outgoing.source, "我发出的申请")
        XCTAssertEqual(outgoing.userID, "self-22")
        XCTAssertFalse(outgoing.isPendingIncoming)
        for (status, label, message) in [("accepted", "已通过", "申请已通过"),
                                          ("rejected", "已拒绝", "申请已拒绝"),
                                          ("cancelled", "已取消", "申请已取消")] {
            let item = try projection(source: "direct_chat_not_friends", status: status)
            XCTAssertEqual(item.source, "来自私聊")
            XCTAssertEqual(item.statusLabel, label)
            XCTAssertEqual(item.message, message)
            XCTAssertFalse(item.isPendingIncoming)
            XCTAssertNotEqual(item.id, "request-pending")
        }
    }
    func testReceiptSyncDecodesAnonymousWatermarkWithoutReaderDetails() throws {
        let result = try JSONDecoder().decode(RemoteMessageReceiptSyncResult.self, from: Data(#"{"items":[],"read_up_to_seq":701,"read_receipts_enabled":true,"can_view_read_receipt_details":false}"#.utf8))
        XCTAssertEqual(result.readUpToSeq, 701)
        XCTAssertEqual(result.readReceiptsEnabled, true)
        XCTAssertEqual(result.canViewReadReceiptDetails, false)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testReceiptSyncMalformedOptionalWatermarkDoesNotDiscardValidDeliveryItems() throws {
        for scalar in ["null", "true", "\"not-a-sequence\"", "{}", "[]", "1.5", "9223372036854775808"] {
            let data = Data("""
            {"items":[{"message_id":"delivery-1","channel_id":"peer:self","channel_type":"direct","from_uid":"self","receipt_type":"delivered","channel_seq":42}],"read_up_to_seq":\(scalar)}
            """.utf8)
            let result = try JSONDecoder().decode(RemoteMessageReceiptSyncResult.self, from: data)
            XCTAssertNil(result.readUpToSeq, "invalid optional scalar: \(scalar)")
            XCTAssertEqual(result.items.count, 1)
            XCTAssertEqual(result.items.first?.receiptType, "delivered")
            XCTAssertNil(result.canViewReadReceiptDetails)
        }
    }

    func testReceiptSyncMissingWatermarkPreservesLegacyDTOContract() throws {
        let result = try JSONDecoder().decode(RemoteMessageReceiptSyncResult.self, from: Data(#"{"items":[],"feature_status":"disabled","read_receipts_enabled":false}"#.utf8))
        XCTAssertNil(result.readUpToSeq)
        XCTAssertEqual(result.readReceiptsEnabled, false)
        XCTAssertEqual(result.featureStatus, "disabled")
    }

    func testAuthSessionDecodesAuthoritativeLifetimeModeWithoutTrustingClientType() throws {
        let permanent = try JSONDecoder().decode(RemoteAuthSession.self, from: Data(#"{"session_id":"sess-ios-1","refresh_token":"refresh-ios-1","refresh_expires_at":1,"access_expires_at":900,"client_type":"web","token_type":"im","lifetime_mode":"until_revoked"}"#.utf8))
        let legacy = try JSONDecoder().decode(RemoteAuthSession.self, from: Data(#"{"sessionId":"sess-legacy-1","refreshToken":"refresh-legacy-1","refreshExpiresAt":1,"clientType":"ios","tokenType":"im"}"#.utf8))

        XCTAssertEqual(permanent.lifetimeMode, .untilRevoked)
        XCTAssertEqual(legacy.lifetimeMode, .absolute)
        XCTAssertEqual(legacy.clientType, "ios", "client_type stays descriptive and must not grant permanence")
    }

    func testAuthSessionUnknownLifetimeModeFailsClosedToAbsolute() throws {
        let session = try JSONDecoder().decode(RemoteAuthSession.self, from: Data(#"{"session_id":"sess-1","refresh_token":"refresh-1","lifetime_mode":"forever"}"#.utf8))

        XCTAssertEqual(session.lifetimeMode, .absolute)
    }

    func testConversationReadWatermarkDecodesFrozenScopeWithoutMessageContent() throws {
        let watermark = try JSONDecoder().decode(RemoteConversationReadWatermark.self, from: Data("""
        {
          "event_id": "read-event-1",
          "tenant_id": "tenant-a",
          "im_uid": "user-a",
          "app_id": "app-ios",
          "channel_id": "channel-a",
          "channel_type": "direct",
          "last_read_seq": 42,
          "occurred_at": "2026-08-26T00:00:00Z"
        }
        """.utf8))

        XCTAssertEqual(watermark.eventID, "read-event-1")
        XCTAssertEqual(watermark.tenantID, "tenant-a")
        XCTAssertEqual(watermark.imUID, "user-a")
        XCTAssertEqual(watermark.appID, "app-ios")
        XCTAssertEqual(watermark.channelID, "channel-a")
        XCTAssertEqual(watermark.channelType, "direct")
        XCTAssertEqual(watermark.lastReadSeq, 42)
        XCTAssertEqual(watermark.occurredAt, "2026-08-26T00:00:00Z")
    }

    func testRemoteConversationDecodesAuthoritativeGroupAvatarTuple() throws {
        let conversation = try JSONDecoder().decode(RemoteConversation.self, from: Data("""
        {
          "channel_id": "group-1",
          "channel_type": "group",
          "avatar": "/api/tenant/avatar/group-file",
          "avatar_version": "version-2",
          "avatar_updated_at": "2026-08-13T00:00:00Z"
        }
        """.utf8))

        XCTAssertTrue(conversation.avatarProvided)
        XCTAssertEqual(conversation.avatar, "/api/tenant/avatar/group-file")
        XCTAssertEqual(conversation.avatarVersion, "version-2")
        XCTAssertEqual(conversation.avatarUpdatedAt, "2026-08-13T00:00:00Z")
    }

}
