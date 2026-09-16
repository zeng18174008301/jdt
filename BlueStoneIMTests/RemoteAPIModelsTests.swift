import XCTest
@testable import BlueStoneIM

final class RemoteAPIModelsTests: XCTestCase {
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

    func testTURNRouteCapabilityDecodeIsOptionalAndDoesNotFailMedia() throws {
        for value in ["null", "42", "{}", "{\"schema_version\":\"future\"}"] {
            let media = try JSONDecoder().decode(RemoteRTCMedia.self,
                from: Data("{\"turn_route_telemetry\":\(value)}".utf8))
            var collector = RTCTurnRouteCollector(capability: media.turnRouteTelemetry)
            XCTAssertNil(collector.observe(makeTURNRecords()))
        }
        let media = try JSONDecoder().decode(RemoteRTCMedia.self, from: Data("{}".utf8))
        XCTAssertNil(media.turnRouteTelemetry)
    }

    func testTURNRouteUsesOnlyAuthoritativeLocalSelectionAndScrubsWirePayload() throws {
        let capability = makeTURNCapability()
        var collector = RTCTurnRouteCollector(capability: capability)
        var records = makeTURNRecords()
        let first = try XCTUnwrap(collector.observe(records))
        XCTAssertEqual(first.transports.count, 1)
        XCTAssertEqual(first.transports[0].nodeID, capability.nodes[0].nodeID)
        XCTAssertEqual(first.transports[0].localRelayProtocol, "udp")
        XCTAssertEqual(first.transports[0].bytesSent, 100)
        let wire = String(data: try JSONSerialization.data(withJSONObject: first.requestBody), encoding: .utf8)!
        for forbidden in ["relay.example", "pair-private", "transport-private", "turn:", "url", "username", "credential"] {
            XCTAssertFalse(wire.contains(forbidden))
        }
        records.removeFirst()
        let unknown = try XCTUnwrap(collector.observe(records)).transports[0]
        XCTAssertEqual(unknown.selectionBasis, "unavailable")
        XCTAssertEqual(unknown.unknownReason, "selection_unavailable")
        XCTAssertEqual(unknown.localCandidateType, "unknown")
        XCTAssertNil(unknown.nodeID)
        XCTAssertNil(unknown.bytesSent)
    }

    func testTURNRouteEpochDirectoryAndConnectionLifetimesStaySeparate() throws {
        let capability = makeTURNCapability()
        var collector = RTCTurnRouteCollector(capability: capability)
        let first = try XCTUnwrap(collector.observe(makeTURNRecords()))
        let same = try XCTUnwrap(collector.observe(makeTURNRecords()))
        XCTAssertEqual(first, same)
        var changed = makeTURNRecords()
        changed[0] = RTCQualityStatRecord(id: "transport-private", type: "transport", selectedCandidatePairID: "other")
        let next = try XCTUnwrap(collector.observe(changed))
        XCTAssertEqual(next.transports[0].routeEpoch, 2)
        XCTAssertEqual(next.transports[0].transportID, first.transports[0].transportID)
        XCTAssertEqual(next.transports[0].unknownReason, "candidate_unavailable")
        collector.enableIfPreviouslyUnavailable(makeTURNCapability(version: String(repeating: "b", count: 64)))
        XCTAssertNil(collector.observe(makeTURNRecords()))
        XCTAssertEqual(first.mappingVersion, capability.mappingVersion)
        var replacement = RTCTurnRouteCollector(capability: capability)
        let rebuilt = try XCTUnwrap(replacement.observe(makeTURNRecords()))
        XCTAssertNotEqual(rebuilt.connectionID, first.connectionID)
        XCTAssertEqual(rebuilt.transports[0].routeEpoch, 1)
    }

    func testTURNRouteCountersArePairedAndAmbiguousDirectoryStaysUnknown() throws {
        var capability = makeTURNCapability()
        capability = RemoteRTCTurnRouteTelemetry(schemaVersion: capability.schemaVersion,
            mappingVersion: capability.mappingVersion, nodes: capability.nodes + [
                .init(nodeID: "tn_" + String(repeating: "b", count: 32), urls: capability.nodes[0].urls)
            ])
        var collector = RTCTurnRouteCollector(capability: capability)
        var records = makeTURNRecords()
        records[1] = RTCQualityStatRecord(id: "pair-private", type: "candidate-pair",
            localCandidateID: "local", remoteCandidateID: "remote", bytesReceived: 10, bytesSent: 9_007_199_254_740_992)
        let transport = try XCTUnwrap(collector.observe(records)).transports[0]
        XCTAssertEqual(transport.unknownReason, "mapping_unavailable")
        XCTAssertNil(transport.nodeID)
        XCTAssertNil(transport.bytesSent)
        XCTAssertNil(transport.bytesReceived)
        records[2] = RTCQualityStatRecord(id: "local", type: "local-candidate", candidateType: "host", protocolName: "tcp")
        let direct = try XCTUnwrap(collector.observe(records)).transports[0]
        XCTAssertEqual(direct.localRelayProtocol, "unknown", "remote TLS and ICE TCP must not become local relay protocol")
        XCTAssertNil(direct.nodeID)
    }

    func testTURNRouteMissingTransportsBreaksIntervalsWithoutConsumingSlots() throws {
        var collector = RTCTurnRouteCollector(capability: makeTURNCapability())
        XCTAssertEqual(collector.observe([])?.transports[0].selectionBasis, "unavailable")
        let records = Array(makeTURNRecords().suffix(2)) + (1...8).flatMap { number in
            [RTCQualityStatRecord(id: "transport-\(number)", type: "transport", selectedCandidatePairID: "pair-\(number)"),
             RTCQualityStatRecord(id: "pair-\(number)", type: "candidate-pair", localCandidateID: "local", remoteCandidateID: "remote", bytesReceived: 200, bytesSent: 100)]
        }
        let before = try XCTUnwrap(collector.observe(records))
        XCTAssertEqual(before.transports.count, 8)
        _ = collector.observe([])
        let after = try XCTUnwrap(collector.observe(records))
        XCTAssertEqual(after.transports.count, 8)
        XCTAssertGreaterThan(after.transports[0].routeEpoch, before.transports[0].routeEpoch)
    }

    func testTURNRouteAliasesDoNotDuplicatePairCountersWhenReportsReorder() throws {
        var collector = RTCTurnRouteCollector(capability: makeTURNCapability())
        let records = makeTURNRecords() + [RTCQualityStatRecord(id: "zz-alias", type: "transport", selectedCandidatePairID: "pair-private")]
        let first = try XCTUnwrap(collector.observe(records))
        XCTAssertEqual(first.transports.count, 1)
        XCTAssertEqual(first.transports[0].bytesSent, 100)
        XCTAssertEqual(collector.observe(Array(records.reversed())), first)
    }

    @MainActor
    func testTURNQualitySequenceSurvivesNewLedgerAndSeparatesRoles() throws {
        let suite = "turn-route-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RTCQualitySequenceLedger(defaults: defaults)
        XCTAssertEqual(first.reserve(callKey: "call|caller"), 1)
        XCTAssertEqual(first.reserve(callKey: "call|caller"), 2)
        let restored = RTCQualitySequenceLedger(defaults: defaults)
        XCTAssertEqual(restored.reserve(callKey: "call|caller"), 3)
        XCTAssertEqual(restored.reserve(callKey: "call|callee"), 1)
        for corruptValue in [true, false, 1.5, "corrupt"] as [Any] {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rtc.quality.sequence.v1.") {
                defaults.set(corruptValue, forKey: key)
            }
            XCTAssertNil(RTCQualitySequenceLedger(defaults: defaults).reserve(callKey: "call|caller"))
        }
    }

    @MainActor
    func testTURNQualityTailReportScopeAndDeadline() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["scopes": ["rtc:quality:write"]])
        let token = "e30." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".fixture"
        let context = IMAPIContext(
            platformToken: nil, accountID: "account", tenantID: "tenant", imUID: "uid", imToken: "fixture",
            platformAuthSession: nil, tenantAuthSession: nil, appID: "jianhuitong-ios", deviceID: "device", sessionEpoch: "epoch"
        )
        var uptime: TimeInterval = 100
        func session() -> RTCQualityReportingSession {
            RTCQualityReportingSession(context: context, scope: "scope", callID: "call", roomID: "room",
                direction: "caller", mediaMode: "video", generation: 7, rtcToken: token, uptime: { uptime })
        }
        func report(_ session: RTCQualityReportingSession, current: IMAPIContext,
                    callID: String? = "call", direction: String? = "caller", generation: UInt64 = 7) throws {
            _ = try session.requestContext(current: current, authenticated: true, scopeIsCurrent: true, licensed: true,
                activeCallID: callID, activeDirection: direction, generation: generation, rtcToken: token)
        }
        let ending = session()
        XCTAssertNoThrow(try report(ending, current: context))
        ending.finish()
        uptime = 104
        XCTAssertNoThrow(try report(ending, current: context, callID: nil, direction: nil, generation: 8))
        ending.finish()
        uptime = 105
        XCTAssertThrowsError(try report(ending, current: context, callID: nil, direction: nil, generation: 8))
        let switched = session()
        switched.finish()
        var other = context
        other.accountID = "other"
        XCTAssertThrowsError(try report(switched, current: other))
        XCTAssertThrowsError(try report(switched, current: context))
        XCTAssertThrowsError(try report(session(), current: context, callID: "another-call"))
        XCTAssertThrowsError(try report(session(), current: context, direction: "callee"))
        XCTAssertTrue(RTCQualityUploadFailurePolicy.isTerminal(CancellationError()))
    }

    private func makeTURNCapability(version: String = String(repeating: "a", count: 64)) -> RemoteRTCTurnRouteTelemetry {
        .init(schemaVersion: "rtc-turn-route-v1", mappingVersion: version, nodes: [
            .init(nodeID: "tn_" + String(repeating: "a", count: 32), urls: ["turn:relay.example:3478?transport=udp"])
        ])
    }

    private func makeTURNRecords() -> [RTCQualityStatRecord] {
        [RTCQualityStatRecord(id: "transport-private", type: "transport", selectedCandidatePairID: "pair-private"),
         RTCQualityStatRecord(id: "pair-private", type: "candidate-pair", localCandidateID: "local", remoteCandidateID: "remote",
            selected: true, nominated: true, currentRoundTripTimeSeconds: 0.05, bytesReceived: 200, bytesSent: 100),
         RTCQualityStatRecord(id: "local", type: "local-candidate", candidateType: "relay", protocolName: "tcp",
            relayProtocol: "udp", candidateURL: "turn:relay.example:3478?transport=udp"),
         RTCQualityStatRecord(id: "remote", type: "remote-candidate", candidateType: "relay", relayProtocol: "tls")]
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

    func testRTCQualityTokenScopeFailsClosedAndAcceptsOnlyDedicatedWriteScope() throws {
        let allowed = try makeRTCQualityToken(scopes: ["rtc:room:join", "rtc:quality:write"])
        let signalOnly = try makeRTCQualityToken(scopes: ["rtc:signal:send"])

        XCTAssertTrue(RTCQualityTokenScope.hasWriteScope(allowed))
        XCTAssertFalse(RTCQualityTokenScope.hasWriteScope(signalOnly))
        XCTAssertFalse(RTCQualityTokenScope.hasWriteScope("not-a-jwt"))
        XCTAssertFalse(RTCQualityTokenScope.hasWriteScope(""))
    }

    func testRTCQualityReducerExtractsOnlyDeidentifiedSelectedRouteAndIntervalMetrics() throws {
        var reducer = RTCQualitySampleReducer()
        let first = [
            RTCQualityStatRecord(
                id: "transport-1",
                type: "transport",
                timestampUS: 1_000_000,
                selectedCandidatePairID: "pair-1"
            ),
            RTCQualityStatRecord(
                id: "pair-1",
                type: "candidate-pair",
                timestampUS: 1_000_000,
                localCandidateID: "local-1",
                remoteCandidateID: "remote-1",
                state: "succeeded",
                selected: true,
                currentRoundTripTimeSeconds: 0.075,
                availableOutgoingBitrateBPS: 1_500_000
            ),
            RTCQualityStatRecord(
                id: "local-1",
                type: "local-candidate",
                timestampUS: 1_000_000,
                candidateType: "relay",
                protocolName: "tcp",
                relayProtocol: "tls"
            ),
            RTCQualityStatRecord(
                id: "remote-1",
                type: "remote-candidate",
                timestampUS: 1_000_000,
                candidateType: "srflx",
                protocolName: "udp"
            ),
            RTCQualityStatRecord(
                id: "inbound-video",
                type: "inbound-rtp",
                timestampUS: 1_000_000,
                jitterSeconds: 0.012,
                packetsLost: 2,
                packetsReceived: 98,
                bytesReceived: 100_000,
                framesPerSecond: 24,
                framesDropped: 5,
                freezeCount: 1
            ),
            RTCQualityStatRecord(
                id: "inbound-audio",
                type: "inbound-rtp",
                timestampUS: 1_000_000,
                packetsLost: 0,
                packetsReceived: 100,
                bytesReceived: 50_000,
                concealedSamples: 100,
                totalSamplesReceived: 10_000
            ),
            RTCQualityStatRecord(
                id: "outbound-video",
                type: "outbound-rtp",
                timestampUS: 1_000_000,
                bytesSent: 200_000,
                framesPerSecond: 30
            )
        ]
        let firstSample = try XCTUnwrap(
            reducer.reduce(records: first, sampledAt: Date(timeIntervalSince1970: 1), sampleSeq: 1)
        )
        XCTAssertEqual(firstSample.connectionRoute, "relay")
        XCTAssertEqual(firstSample.candidateProtocol, "tls")
        XCTAssertEqual(try XCTUnwrap(firstSample.rttMS), 75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(firstSample.jitterMS), 12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(firstSample.packetLossPct), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(firstSample.availableOutgoingBitrateKbps), 1_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(firstSample.framesPerSecond), 30)
        XCTAssertNil(firstSample.framesDropped, "cumulative counters must not be uploaded as per-sample deltas")
        XCTAssertNil(firstSample.freezeCount)

        let second = first.map { record -> RTCQualityStatRecord in
            switch record.id {
            case "inbound-video":
                return RTCQualityStatRecord(
                    id: record.id,
                    type: record.type,
                    timestampUS: 11_000_000,
                    jitterSeconds: 0.020,
                    packetsLost: 3,
                    packetsReceived: 197,
                    bytesReceived: 1_100_000,
                    framesPerSecond: 25,
                    framesDropped: 7,
                    freezeCount: 2
                )
            case "inbound-audio":
                return RTCQualityStatRecord(
                    id: record.id,
                    type: record.type,
                    timestampUS: 11_000_000,
                    packetsLost: 0,
                    packetsReceived: 200,
                    bytesReceived: 550_000,
                    concealedSamples: 110,
                    totalSamplesReceived: 20_000
                )
            case "outbound-video":
                return RTCQualityStatRecord(
                    id: record.id,
                    type: record.type,
                    timestampUS: 11_000_000,
                    bytesSent: 1_200_000,
                    framesPerSecond: 29
                )
            default:
                return RTCQualityStatRecord(
                    id: record.id,
                    type: record.type,
                    timestampUS: 11_000_000,
                    selectedCandidatePairID: record.selectedCandidatePairID,
                    localCandidateID: record.localCandidateID,
                    remoteCandidateID: record.remoteCandidateID,
                    candidateType: record.candidateType,
                    protocolName: record.protocolName,
                    relayProtocol: record.relayProtocol,
                    state: record.state,
                    selected: record.selected,
                    nominated: record.nominated,
                    currentRoundTripTimeSeconds: record.currentRoundTripTimeSeconds,
                    availableOutgoingBitrateBPS: record.availableOutgoingBitrateBPS
                )
            }
        }
        let secondSample = try XCTUnwrap(
            reducer.reduce(records: second, sampledAt: Date(timeIntervalSince1970: 11), sampleSeq: 2)
        )
        XCTAssertEqual(try XCTUnwrap(secondSample.inboundBitrateKbps), 1_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(secondSample.outboundBitrateKbps), 800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(secondSample.packetLossPct), 0.5, accuracy: 0.001)
        XCTAssertEqual(secondSample.framesDropped, 2)
        XCTAssertEqual(secondSample.freezeCount, 1)

        let body = secondSample.requestBody
        let allowedKeys: Set<String> = [
            "sampled_at", "sample_seq", "connection_route", "candidate_protocol",
            "rtt_ms", "jitter_ms", "packet_loss_pct",
            "available_outgoing_bitrate_kbps", "inbound_bitrate_kbps",
            "outbound_bitrate_kbps", "frames_per_second", "frames_dropped",
            "audio_concealment_pct", "freeze_count"
        ]
        XCTAssertTrue(Set(body.keys).isSubset(of: allowedKeys))
        for forbidden in ["ip", "address", "port", "sdp", "device", "username", "candidate_id", "media"] {
            XCTAssertFalse(body.keys.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }
    }

    @MainActor
    func testRTCQualityLifecycleBackgroundAndStopFlushWithoutBlockingMediaState() async throws {
        let token = try makeRTCQualityToken(scopes: ["rtc:quality:write"])
        var uploadBatches: [[RTCQualitySample]] = []
        var timestamp: Double = 1_000_000
        let session = RTCQualityTelemetrySession(
            rtcToken: token,
            statsProvider: {
                defer { timestamp += 10_000_000 }
                return [
                    RTCQualityStatRecord(
                        id: "pair",
                        type: "candidate-pair",
                        timestampUS: timestamp,
                        localCandidateID: "local",
                        remoteCandidateID: "remote",
                        selected: true,
                        currentRoundTripTimeSeconds: 0.05
                    ),
                    RTCQualityStatRecord(
                        id: "local",
                        type: "local-candidate",
                        timestampUS: timestamp,
                        candidateType: "host",
                        protocolName: "udp"
                    )
                ]
            },
            reporter: { samples, _ in
                uploadBatches.append(samples)
            },
            now: { Date(timeIntervalSince1970: timestamp / 1_000_000) }
        )

        await session.captureForTesting(forceUpload: false)
        XCTAssertEqual(session.pendingCountForTesting, 1)
        await session.applicationDidEnterBackground()
        await waitUntil { uploadBatches.count == 1 }
        XCTAssertEqual(uploadBatches.first?.map(\.sampleSeq), [1, 2])
        XCTAssertEqual(session.pendingCountForTesting, 0)

        await session.stop()
        await waitUntil { uploadBatches.count == 2 }
        XCTAssertTrue(session.isStoppedForTesting)
        XCTAssertEqual(uploadBatches.last?.map(\.sampleSeq), [3])
    }

    func testVideoConnectionGateRequiresPeerConnectionAndAnyRemoteMediaTrack() {
        var gate = RTCVideoConnectionGate()
        XCTAssertFalse(gate.apply(.mediaConnected))
        XCTAssertTrue(gate.apply(.remoteAudioTrackReady))
        XCTAssertFalse(gate.apply(.remoteVideoTrackReady))

        var reverseOrder = RTCVideoConnectionGate()
        XCTAssertFalse(reverseOrder.apply(.remoteVideoTrackReady))
        XCTAssertTrue(reverseOrder.apply(.mediaConnected))
        XCTAssertFalse(reverseOrder.apply(.reconnecting))
        XCTAssertFalse(reverseOrder.apply(.mediaConnected), "reconnect must not restart connected timing")
    }

    func testVideoFrameStatsSummaryContainsOnlyFramePathCountersAndCodec() {
        let records = [
            RTCQualityStatRecord(id: "codec-1", type: "codec", mimeType: "video/H264"),
            RTCQualityStatRecord(
                id: "outbound-video",
                type: "outbound-rtp",
                bytesSent: 4_567,
                kind: "video",
                codecID: "codec-1",
                ssrc: "1234",
                framesEncoded: 34,
                framesSent: 33
            ),
            RTCQualityStatRecord(
                id: "inbound-video",
                type: "inbound-rtp",
                bytesReceived: 4_000,
                mediaType: "video",
                codecID: "codec-1",
                ssrc: "5678",
                framesReceived: 30,
                framesDecoded: 29
            ),
        ]

        let summary = rtcVideoFrameStatsSummary(records)

        XCTAssertTrue(summary.contains("encoded=34,sent=33"))
        XCTAssertTrue(summary.contains("received=30,decoded=29"))
        XCTAssertTrue(summary.contains("codec=video/H264"))
        XCTAssertTrue(summary.contains("ssrc=1234"))
    }

    private func makeRTCQualityToken(scopes: [String]) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: ["scopes": scopes])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition(),
              DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }

    func testVideoConnectionGateDoesNotMarkConnectedOnTrackOnly() {
        var gate = RTCVideoConnectionGate()
        XCTAssertFalse(gate.apply(.remoteAudioTrackReady))
        XCTAssertFalse(gate.didEmitConnected)
    }

    func testVideoSignalRuntimeRebindInvalidatesOldPollWithoutLosingCursorOrDedupe() {
        var state = RTCVideoSignalRuntimeState(rtcToken: "old")
        let oldGeneration = state.generation
        state.markProcessed("message-1")
        state.commitCursor("cursor-1")
        state.rebindToken("new")

        XCTAssertEqual(state.rtcToken, "new")
        XCTAssertFalse(state.isCurrent(generation: oldGeneration))
        XCTAssertEqual(state.cursor, "cursor-1")
        XCTAssertTrue(state.hasProcessed("message-1"))
    }

    @MainActor
    func testVideoIceRestartBatchDefersPollGenerationUntilAckAndDoesNotReplay() async throws {
        let kinds: [RemoteRTCSignalKind] = [
            .iceRestart,
            .mediaState,
            .answer,
            .candidate,
            .candidate,
            .candidate,
            .candidate,
            .candidate
        ]
        let items = kinds.enumerated().map { index, kind in
            RemoteRTCSignalItem(
                serverCursor: "\(index + 1)-0",
                messageID: "recovery-message-\(index + 1)",
                seq: index + 5,
                kind: kind
            )
        }
        var state = RTCVideoSignalRuntimeState(rtcToken: "old-token")
        let activeGeneration = state.generation
        var inBandRefresh = RTCVideoInBandCredentialRefreshState()
        var handled: [String] = []

        state.stageTokenRebind("refreshed-token")
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))

        try await RTCVideoSignalBatchProcessor.process(
            items,
            state: &state,
            generation: activeGeneration
        ) { item in
            handled.append(item.messageID)
            if item.kind == .iceRestart {
                inBandRefresh.request()
            }
        }

        XCTAssertEqual(handled, items.map(\.messageID))
        XCTAssertTrue(items.allSatisfy { state.hasProcessed($0.messageID) })
        XCTAssertTrue(inBandRefresh.isPending)
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))
        XCTAssertEqual(state.rtcToken, "refreshed-token")
        XCTAssertEqual(state.cursor, "", "cursor must not advance before ACK succeeds")

        inBandRefresh.requireAcknowledgement(of: "8-0")
        XCTAssertFalse(
            inBandRefresh.completeAfterAcknowledgement(
                acknowledgedCursor: state.cursor,
                didAcknowledgeAndCommit: false
            ),
            "an ACK failure must preserve the pending in-band refresh"
        )
        XCTAssertTrue(inBandRefresh.isPending)

        state.commitCursor("8-0")
        XCTAssertTrue(
            inBandRefresh.completeAfterAcknowledgement(
                acknowledgedCursor: state.cursor,
                didAcknowledgeAndCommit: true
            )
        )

        XCTAssertEqual(state.cursor, "8-0")
        XCTAssertTrue(state.isCurrent(generation: activeGeneration))
        XCTAssertFalse(inBandRefresh.isPending)

        var replayed: [String] = []
        try await RTCVideoSignalBatchProcessor.process(
            items,
            state: &state,
            generation: state.generation
        ) { item in
            replayed.append(item.messageID)
        }
        XCTAssertTrue(replayed.isEmpty)
    }

    func testVideoInBandCredentialRefreshRequiresThisIterationAckAndBlocksOutOfBandRefresh() {
        var refresh = RTCVideoInBandCredentialRefreshState()
        refresh.request()
        refresh.requireAcknowledgement(of: "")
        XCTAssertFalse(
            refresh.completeAfterAcknowledgement(
                acknowledgedCursor: "",
                didAcknowledgeAndCommit: true
            )
        )
        XCTAssertTrue(refresh.isPending)

        refresh.requireAcknowledgement(of: "cursor-1")
        XCTAssertFalse(
            refresh.completeAfterAcknowledgement(
                acknowledgedCursor: "cursor-1",
                didAcknowledgeAndCommit: false
            ),
            "an unchanged cursor must not be mistaken for an ACK from this iteration"
        )
        XCTAssertTrue(refresh.isPending)
        XCTAssertEqual(
            RTCVideoCredentialRefreshAction.resolve(
                inBandRequest: false,
                inBandRefreshPending: refresh.isPending
            ),
            .rejectOutOfBand
        )
        XCTAssertEqual(
            RTCVideoCredentialRefreshAction.resolve(
                inBandRequest: true,
                inBandRefreshPending: refresh.isPending
            ),
            .retryNegotiation
        )
    }

    func testVideoCredentialRefreshSnapshotRejectsClosedOrReplacementSession() {
        let snapshot = RTCVideoCredentialRefreshSnapshot(
            sessionEpoch: 7,
            callID: "call-old",
            roomID: "room-old",
            rtcToken: "token-old"
        )
        XCTAssertTrue(
            snapshot.matches(
                sessionEpoch: 7,
                callID: "call-old",
                roomID: "room-old",
                rtcToken: "token-old"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 8,
                callID: "call-new",
                roomID: "room-new",
                rtcToken: "token-new"
            ),
            "a refresh response from a closed call must not mutate its replacement session"
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 8,
                callID: "call-old",
                roomID: "room-old",
                rtcToken: "token-old"
            ),
            "session epoch must reject same-ID call reuse"
        )
    }

    @MainActor
    func testVideoSignalBatchMarksOnlySuccessfullyHandledItemsAndStopsAtFailure() async {
        enum ExpectedFailure: Error { case failedItem }
        let items = [
            RemoteRTCSignalItem(messageID: "message-1", kind: .mediaState),
            RemoteRTCSignalItem(messageID: "message-2", kind: .candidate),
            RemoteRTCSignalItem(messageID: "message-3", kind: .bye)
        ]
        var state = RTCVideoSignalRuntimeState(rtcToken: "token")
        let generation = state.generation
        var handled: [String] = []

        do {
            try await RTCVideoSignalBatchProcessor.process(
                items,
                state: &state,
                generation: generation
            ) { item in
                handled.append(item.messageID)
                if item.messageID == "message-2" {
                    throw ExpectedFailure.failedItem
                }
            }
            XCTFail("expected item handling failure")
        } catch is ExpectedFailure {
            XCTAssertEqual(handled, ["message-1", "message-2"])
            XCTAssertTrue(state.hasProcessed("message-1"))
            XCTAssertFalse(state.hasProcessed("message-2"))
            XCTAssertFalse(state.hasProcessed("message-3"))
            XCTAssertEqual(state.cursor, "", "cursor must remain uncommitted until ACK succeeds")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVideoSignalOutboxKeepsStableEnvelopeAndFailsClosedAtCapacity() throws {
        let first = RemoteRTCSignalEnvelope(
            messageID: "message-1",
            seq: 7,
            kind: .candidate,
            data: ["candidate": .string("redacted-test-candidate")]
        )
        let second = RemoteRTCSignalEnvelope(messageID: "message-2", seq: 8, kind: .offer)
        var outbox = RTCVideoSignalOutbox(capacity: 1)

        try outbox.enqueue(first)
        try outbox.enqueue(first)
        XCTAssertEqual(outbox.pending, [first])
        XCTAssertThrowsError(try outbox.enqueue(second)) {
            XCTAssertEqual($0 as? RTCVideoSignalOutboxError, .capacityExceeded)
        }
        outbox.markDelivered(messageID: first.messageID)
        XCTAssertTrue(outbox.pending.isEmpty)

        try outbox.enqueue(first)
        outbox.reset()
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    func testVideoMediaStatePayloadUsesOnlyServerWhitelistedKeys() {
        let noCamera = RTCVideoMediaStatePayload.make(
            cameraEnabled: false,
            mediaMode: "video"
        )
        XCTAssertEqual(
            Set(noCamera.keys),
            Set(["camera_enabled", "media_mode"])
        )
        XCTAssertEqual(noCamera["camera_enabled"], .bool(false))
        XCTAssertEqual(noCamera["media_mode"], .string("video"))
        XCTAssertNil(noCamera["camera_unavailable"])
        XCTAssertNil(noCamera["app_backgrounded"])

        let backgrounded = RTCVideoMediaStatePayload.make(
            cameraEnabled: false,
            microphoneEnabled: true,
            mediaMode: "video"
        )
        XCTAssertEqual(
            Set(backgrounded.keys),
            Set(["camera_enabled", "microphone_enabled", "media_mode"])
        )
        XCTAssertNil(backgrounded["app_backgrounded"])
    }

    func testVideoSignalOutboxSupersedesBestEffortStateWithoutReorderingSequence() throws {
        let firstMediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state-1",
            seq: 1,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: true, mediaMode: "video")
        )
        let secondMediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state-2",
            seq: 2,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: false, mediaMode: "video")
        )
        let answer = RemoteRTCSignalEnvelope(messageID: "answer-1", seq: 3, kind: .answer)
        let firstCandidate = RemoteRTCSignalEnvelope(messageID: "candidate-1", seq: 4, kind: .candidate)
        let secondCandidate = RemoteRTCSignalEnvelope(messageID: "candidate-2", seq: 5, kind: .candidate)
        var outbox = RTCVideoSignalOutbox(capacity: 8)

        try outbox.enqueue(firstMediaState)
        try outbox.enqueue(secondMediaState)
        XCTAssertEqual(
            outbox.pending,
            [secondMediaState],
            "only the latest unsent best-effort media state is useful"
        )

        try outbox.enqueue(answer)
        try outbox.enqueue(firstCandidate)
        try outbox.enqueue(secondCandidate)
        XCTAssertEqual(
            outbox.pending.map(\.messageID),
            ["answer-1", "candidate-1", "candidate-2"],
            "later SDP/ICE discards stale lower-sequence media state and preserves critical order"
        )
        XCTAssertEqual(outbox.pending.map(\.seq), [3, 4, 5])
    }

    func testVideoSignalOutboxKeepsExactCriticalEnvelopeForRetryableFailure() throws {
        let envelope = RemoteRTCSignalEnvelope(
            messageID: "stable-message-id",
            seq: 77,
            kind: .candidate,
            data: ["candidate": .string("redacted-test-candidate")],
            sentAt: "2026-07-26T00:00:00Z"
        )
        var outbox = RTCVideoSignalOutbox()

        try outbox.enqueue(envelope)
        let firstAttempt = try XCTUnwrap(outbox.pending.first)
        // A retryable HTTP/network failure deliberately does not call
        // markDelivered. The next flush must resend the exact same envelope.
        let retryAttempt = try XCTUnwrap(outbox.pending.first)

        XCTAssertEqual(retryAttempt, firstAttempt)
        XCTAssertEqual(retryAttempt.messageID, "stable-message-id")
        XCTAssertEqual(retryAttempt.seq, 77)
        XCTAssertEqual(retryAttempt.sentAt, "2026-07-26T00:00:00Z")
    }

    func testVideoSignalOutboxDiscardsBestEffortStateWhenCriticalSignalNeedsCapacity() throws {
        let mediaState = RemoteRTCSignalEnvelope(
            messageID: "media-state",
            seq: 1,
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(cameraEnabled: false, mediaMode: "video")
        )
        let answer = RemoteRTCSignalEnvelope(messageID: "answer", seq: 2, kind: .answer)
        var outbox = RTCVideoSignalOutbox(capacity: 1)

        try outbox.enqueue(mediaState)
        try outbox.enqueue(answer)

        XCTAssertEqual(outbox.pending, [answer])
    }

    func testVideoSignalFailurePolicyOnlyRecognizesExactAuthoritativeTerminalPairs() {
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(
                    statusCode: 409,
                    code: "rtc-call-not-active",
                    message: "terminal"
                )
            )
        )
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(
                    statusCode: 404,
                    code: "RTC_CALL_NOT_FOUND",
                    message: "terminal"
                )
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 409, code: "conflict", message: "retry")
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 404, code: "route_not_found", message: "retry")
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(
                RTCVideoSignalHTTPError(statusCode: 503, code: "rtc_call_not_active", message: "retry")
            )
        )
    }

    func testVideoSignalFailurePolicyDropsOnlyInvalidBestEffortMediaState() {
        let invalidPayload = RTCVideoSignalHTTPError(
            statusCode: 422,
            code: "RTC-SIGNAL-PAYLOAD-INVALID",
            message: "redacted"
        )
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: invalidPayload
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .answer,
                after: invalidPayload
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: RTCVideoSignalHTTPError(
                    statusCode: 503,
                    code: "rtc_signal_payload_invalid",
                    message: "retry"
                )
            ),
            "retryable failures must keep the original envelope"
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: URLError(.networkConnectionLost)
            ),
            "network failures must keep the original envelope"
        )
    }

    func testVideoSignalLongPollTimeoutDoesNotDegradeConnectedMedia() {
        XCTAssertFalse(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.timedOut),
                iceConnected: true
            )
        )
        XCTAssertTrue(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.timedOut),
                iceConnected: false
            )
        )
        XCTAssertTrue(
            RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                after: URLError(.networkConnectionLost),
                iceConnected: true
            )
        )
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func testVideoSignalPollingFailureBackoffUsesExponentialFloorWithJitter() {
        var state = RTCVideoSignalPollingBackoffState()

        let first = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")
        let second = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")

        XCTAssertGreaterThanOrEqual(first, 1_000_000_000)
        XCTAssertLessThan(first, 1_200_000_000)
        XCTAssertGreaterThanOrEqual(second, 2_000_000_000)
        XCTAssertLessThan(second, 2_400_000_000)

        state.reset()
        let resetFirst = state.recordFailureAndDelayNanoseconds(stableKey: "call-a")
        XCTAssertGreaterThanOrEqual(resetFirst, 1_000_000_000)
        XCTAssertLessThan(resetFirst, 1_200_000_000)
    }

    func testVideoSignalPollingQuickEmptyDelayOnlyForFastEmptyNoCursorProgress() {
        XCTAssertTrue(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 1,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-2",
                elapsedNanoseconds: 50_000_000
            )
        )
        XCTAssertFalse(
            RTCVideoSignalPollingBackoffPolicy.shouldDelayQuickEmptyPage(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 1_000_000_000
            )
        )
    }

    // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：固定 RTC 连接前空轮询短等待、连接后恢复常规节流
    func testRTCSignalPollingQuickEmptyUsesShortDelayBeforeConnected() {
        XCTAssertEqual(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000,
                isConnected: false
            ),
            150_000_000
        )
        XCTAssertEqual(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 50_000_000,
                isConnected: true
            ),
            1_000_000_000
        )
        XCTAssertNil(
            RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                itemCount: 0,
                previousCursor: "cursor-1",
                nextCursor: "cursor-1",
                elapsedNanoseconds: 150_000_000,
                isConnected: false
            )
        )
    }
    // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func testVideoSignalLongPollTimeoutAlwaysExceedsServerWait() {
        let waitMS = RTCVideoSignalLongPollPolicy.normalizedWaitMS(25_000)
        let timeout = RTCVideoSignalLongPollPolicy.requestTimeout(waitMS: waitMS)

        XCTAssertEqual(waitMS, 25_000)
        XCTAssertEqual(timeout, 30)
        XCTAssertGreaterThan(timeout, TimeInterval(waitMS) / 1_000)
    }

    func testRemoteRTCCallDecodesTerminalReasonAndVersionFromSnakeAndCamelCase() throws {
        let snake = try JSONDecoder().decode(
            RemoteRTCCall.self,
            from: Data(#"{"id":"call-snake","status":"ended","end_reason":"caller_hangup","state_version":"12"}"#.utf8)
        )
        XCTAssertEqual(snake.endReason, "caller_hangup")
        XCTAssertEqual(snake.stateVersion, 12)

        let camel = try JSONDecoder().decode(
            RemoteRTCCall.self,
            from: Data(#"{"id":"call-camel","status":"ended","endReason":"peer_timeout","stateVersion":13}"#.utf8)
        )
        XCTAssertEqual(camel.endReason, "peer_timeout")
        XCTAssertEqual(camel.stateVersion, 13)
    }

    func testVideoCredentialSchedulePrefersServerRefreshAfter() {
        let now = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        let delay = RTCVideoCredentialSchedule.delay(
            refreshAfter: "2026-07-25T12:08:00Z",
            expiresAt: "2026-07-25T12:20:00Z",
            now: now
        )
        XCTAssertEqual(delay, 480)
    }

    func testVideoICERestartPolicyOnlyLetsCallerCreateRestartOffer() {
        XCTAssertEqual(RTCVideoICERestartPolicy.action(isCaller: true), .restartAndOffer)
        XCTAssertEqual(RTCVideoICERestartPolicy.action(isCaller: false), .requestCallerRestart)
    }

    func testVideoCallDurationFormatter() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: connectedAt.addingTimeInterval(65)), "01:05")
        XCTAssertEqual(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: connectedAt.addingTimeInterval(3_661)), "01:01:01")
    }

    func testRemoteMessageSyncResultDecodesHistoryBoundaryEnvelope() throws {
        let result = try JSONDecoder().decode(RemoteMessageSyncResult.self, from: Data("""
        {
          "items": [
            {
              "message_id": "m421",
              "channel_id": "g1",
              "channel_type": "group",
              "channel_seq": 421,
              "from_uid": "u1",
              "content_type": "text",
              "payload": {},
              "status": "normal"
            }
          ],
          "has_more_before": false,
          "has_more_after": true,
          "next_after_seq": "421",
          "history_visible_from_seq": "421",
          "history_limited": true
        }
        """.utf8))

        XCTAssertEqual(result.items.map(\.messageID), ["m421"])
        XCTAssertEqual(result.hasMoreBefore, false)
        XCTAssertEqual(result.hasMoreAfter, true)
        XCTAssertEqual(result.nextAfterSeq, 421)
        XCTAssertEqual(result.historyVisibleFromSeq, 421)
        XCTAssertTrue(result.historyLimited)
    }

    func testGroupHistoryVisibilityContractDecodesSummarySettingsAndConversationFields() throws {
        let legacySettings = try JSONDecoder().decode(RemoteGroupSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertTrue(legacySettings.historyVisible)

        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "summary": {
            "group_id": "g1",
            "name": "Group",
            "history_visible_from_seq": 421,
            "history_limited": true
          },
          "settings": {
            "history_visible": false
          },
          "my_role": "admin"
        }
        """.utf8))
        XCTAssertEqual(detail.historyVisibleFromSeq, 421)
        XCTAssertTrue(detail.historyLimited)
        XCTAssertFalse(detail.settings.historyVisible)

        let conversation = try JSONDecoder().decode(RemoteConversation.self, from: Data("""
        {
          "channel_id": "g1",
          "channel_type": "group",
          "last_msg_seq": 430,
          "history_visible_from_seq": 421,
          "history_limited": true
        }
        """.utf8))
        XCTAssertEqual(conversation.historyVisibleFromSeq, 421)
        XCTAssertTrue(conversation.historyLimited)
    }

    func testGroupMuteListContractDecodesSummaryDetailSettingsAndItems() throws {
        let legacySettings = try JSONDecoder().decode(RemoteGroupSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertNil(legacySettings.canManageMuteList)
        XCTAssertNil(legacySettings.muteListCount)

        let summary = try JSONDecoder().decode(RemoteGroupSummary.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "Mute Group",
            "group_muted": true,
            "can_manage_mute_list": false,
            "mute_list_count": "2"
          },
          "settings": {
            "can_manage_mute_list": true,
            "mute_list_count": 3
          },
          "group_muted": false,
          "can_manage_mute_list": true,
          "mute_list_count": 3
        }
        """.utf8))
        XCTAssertFalse(summary.groupMuted)
        XCTAssertTrue(summary.canManageMuteList == true)
        XCTAssertEqual(summary.muteListCount, 3)

        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "summary": {
            "group_id": "g1",
            "name": "Mute Group",
            "group_muted": true,
            "can_manage_mute_list": false,
            "mute_list_count": 2
          },
          "settings": {
            "history_visible": true
          },
          "my_role": "admin"
        }
        """.utf8))
        XCTAssertTrue(detail.groupMuted)
        XCTAssertFalse(detail.canManageMuteList == true)
        XCTAssertEqual(detail.muteListCount, 2)

        let list = try JSONDecoder().decode(RemoteList<RemoteGroupMuteListItem>.self, from: Data("""
        {
          "items": [
            {
              "group_id": "g1",
              "target_uid": "uid-target",
              "target_user_id": "WXTAB123456",
              "target_username": "username07",
              "target_nickname": "王同学",
              "target_avatar": "/avatars/a.png",
              "target_role": "member",
              "operator_uid": "uid-admin",
              "operator_name": "管理员",
              "reason": "广告刷屏",
              "created_at": "2026-07-22T10:00:00Z",
              "updated_at": "2026-07-22T10:05:00Z"
            }
          ]
        }
        """.utf8))
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.groupID, "g1")
        XCTAssertEqual(item.targetUID, "uid-target")
        XCTAssertEqual(item.targetUserID, "WXTAB123456")
        XCTAssertEqual(item.targetUsername, "username07")
        XCTAssertEqual(item.targetNickname, "王同学")
        XCTAssertEqual(item.targetAvatar, "/avatars/a.png")
        XCTAssertEqual(item.targetRole, "member")
        XCTAssertEqual(item.operatorUID, "uid-admin")
        XCTAssertEqual(item.operatorName, "管理员")
        XCTAssertEqual(item.reason, "广告刷屏")
    }

    func testRemoteGroupFileDecodesChannelSeqForHistoryBoundaryFiltering() throws {
        let file = try JSONDecoder().decode(RemoteGroupFile.self, from: Data("""
        {
          "file_id": "file-421",
          "name": "visible.pdf",
          "mime_type": "application/pdf",
          "size_bytes": 2048,
          "channel_id": "g1",
          "channel_type": "group",
          "channel_seq": "421"
        }
        """.utf8))

        XCTAssertEqual(file.fileID, "file-421")
        XCTAssertEqual(file.channelID, "g1")
        XCTAssertEqual(file.channelSeq, 421)
    }

    func testRemoteGroupFilePreservesVoiceClassificationFieldsForFileListFiltering() throws {
        let file = try JSONDecoder().decode(RemoteGroupFile.self, from: Data("""
        {
          "file_id": "voice-file-1",
          "name": "voice-legacy.webm",
          "mime_type": "audio/webm",
          "size_bytes": 2048,
          "channel_id": "g1",
          "channel_type": "group",
          "content_type": "file",
          "media_category": "voice",
          "kind": "voice"
        }
        """.utf8))

        XCTAssertEqual(file.contentType, "file")
        XCTAssertEqual(file.mediaCategory, "voice")
        XCTAssertEqual(file.kind, "voice")
    }

    func testRemoteUserFilePreservesVoiceClassificationFieldsForFileListFiltering() throws {
        let file = try JSONDecoder().decode(RemoteUserFileObject.self, from: Data("""
        {
          "file_id": "voice-file-2",
          "file_name": "recording.m4a",
          "mime_type": "audio/mp4",
          "size_bytes": 1024,
          "content_type": "voice",
          "media_category": "audio",
          "kind": "voice"
        }
        """.utf8))

        XCTAssertEqual(file.contentType, "voice")
        XCTAssertEqual(file.mediaCategory, "audio")
        XCTAssertEqual(file.kind, "voice")
    }

    func testRemoteFavoriteAssetsResponseDecodesContractFields() throws {
        let result = try JSONDecoder().decode(RemoteFavoriteAssetsResponse.self, from: Data("""
        {
          "items": [
            {
              "tenant_id": "tenant-1",
              "message_id": "msg-1",
              "channel_id": "group-1",
              "channel_type": "group",
              "channel_seq": "42",
              "from_uid": "WXT000001",
              "sender_uid": "WXT000001",
              "content_type": "file",
              "payload": {
                "file_id": "file-1",
                "file_name": "users_import_template.csv",
                "mime_type": "text/csv",
                "size_bytes": 2048,
                "media_category": "spreadsheet"
              },
              "status": "sent",
              "created_at": "2026-07-04T09:10:11Z",
              "favorited_at": "2026-07-04T09:12:13Z",
              "favorite_version": "7",
              "category": "spreadsheet",
              "display_text": "users_import_template.csv",
              "cursor": "opaque-cursor-1"
            }
          ],
          "next_cursor": "opaque-cursor-2",
          "has_more": true
        }
        """.utf8))

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].tenantID, "tenant-1")
        XCTAssertEqual(result.items[0].messageID, "msg-1")
        XCTAssertEqual(result.items[0].channelSeq, 42)
        XCTAssertEqual(result.items[0].favoriteVersion, 7)
        XCTAssertEqual(result.items[0].payload["file_name"]?.stringValue, "users_import_template.csv")
        XCTAssertEqual(result.items[0].category, "spreadsheet")
        XCTAssertEqual(result.nextCursor, "opaque-cursor-2")
        XCTAssertTrue(result.hasMore)
    }

    func testFavoriteAssetCategoryMappingKeepsFileTabOrder() {
        XCTAssertEqual(FavoriteAssetCategory.displayOrder.map(\.title), ["全部", "PDF", "图片", "视频", "表格", "文档", "压缩包", "音频"])
        XCTAssertEqual(FavoriteAssetCategory(displayTitle: "表格").requestValue, "spreadsheet")
        XCTAssertEqual(FavoriteAssetCategory(displayTitle: "文档").requestValue, "document")
        XCTAssertEqual(FavoriteAssetCategory(serverValue: ""), .all)
        XCTAssertEqual(FavoriteAssetCategory(serverValue: "audio").title, "音频")
    }

    func testPendingWorkspaceCopyDoesNotLookDisabledUnlessTenantIsReallyDisabled() {
        var pending = Enterprise(
            id: "tenant-pending",
            name: "Pending Enterprise",
            code: "WXT880001",
            role: "member",
            status: "pending",
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            joinStatus: "pending",
            applicationStatus: "pending",
            canSwitch: false,
            enterable: false,
            tenantStatus: "pending",
            memberStatus: "pending"
        )

        XCTAssertTrue(pending.isWorkspaceJoinPending)
        XCTAssertEqual(pending.workspaceDisabledDescription, "等待审批")

        pending.tenantStatus = "disabled"
        XCTAssertEqual(pending.workspaceDisabledDescription, "企业已停用")
    }

    func testNotJoinedWorkspaceCanStillApplyToJoin() {
        let item = Enterprise(
            id: "tenant-open",
            name: "Open Enterprise",
            code: "WXT900002",
            role: "member",
            status: "enabled",
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            joinStatus: "not_joined",
            canSwitch: false,
            enterable: false,
            tenantStatus: "enabled",
            disabledReason: "not_joined"
        )

        XCTAssertFalse(item.isWorkspaceJoined)
        XCTAssertFalse(item.isWorkspaceJoinPending)
        XCTAssertFalse(item.isWorkspaceJoinRejected)
        XCTAssertEqual(item.workspaceDisabledDescription, "")
    }

    func testMaskedPhoneDisplayTextSupportsTenDigitPhones() throws {
        XCTAssertEqual(maskedPhoneDisplayText("13800138000", emptyText: "未绑定"), "138****8000")
        XCTAssertEqual(maskedPhoneDisplayText("1900001002", emptyText: "未绑定"), "190*****002")
        XCTAssertEqual(maskedPhoneDisplayText("", emptyText: "未绑定"), "未绑定")
    }

    func testRemoteMyInviteCodeDecodesOrdinaryUserEmptyState() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": false,
          "status": "disabled",
          "reason_code": "member_invite_code_role_not_allowed"
        }
        """.utf8))

        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.reasonCode, "member_invite_code_role_not_allowed")
        XCTAssertNil(result.item)
        XCTAssertFalse(result.isUsableForRegistration)
        XCTAssertTrue(result.shouldHidePersonalInviteModule)
    }

    func testRemoteMyInviteCodeMarksFailedSyncUnavailableForRegistration() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "id": "invite-1",
            "tenant_id": "tenant-1",
            "im_uid": "uid-admin",
            "user_id": "WXT000001",
            "display_name": "Admin",
            "role": "admin",
            "member_invite_code": "WX7K9P2A",
            "status": "active",
            "sync_status": "failed",
            "sync_version": 2,
            "invite_count": 1,
            "joined_count": 0,
            "pending_count": 1
          }
        }
        """.utf8))

        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.memberInviteCode, "WX7K9P2A")
        XCTAssertTrue(result.isSyncFailed)
        XCTAssertFalse(result.isUsableForRegistration)
        XCTAssertFalse(result.shouldHidePersonalInviteModule)
    }

    func testMyInviteCodePresentationShowsAuthorityValueWhileKeepingFailedSyncNonCopyable() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "tenant_id": "tenant-test",
            "im_uid": "member-test",
            "member_invite_code": "YQMTEST1234",
            "status": "active",
            "sync_status": "failed"
          }
        }
        """.utf8))

        let presentation = MyInviteCodePresentation(
            inviteCode: result,
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(presentation.title, "YQMTEST1234")
        XCTAssertEqual(presentation.subtitle, "邀请码暂不可用于注册")
        XCTAssertNil(presentation.copyValue)
        XCTAssertFalse(presentation.isUsableForRegistration)
        XCTAssertTrue(presentation.isWarning)
        XCTAssertFalse(presentation.shouldShowStats)
        XCTAssertTrue(result.matchesAuthority(tenantID: "tenant-test", imUID: "member-test"))
        XCTAssertFalse(result.matchesAuthority(tenantID: "tenant-other", imUID: "member-test"))
    }

    func testMyInviteCodePresentationKeepsExistingCopyAndTruthfulEmptyErrorStates() throws {
        let usable = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "member_invite_code": "YQMTEST5678",
            "status": "active",
            "sync_status": "synced"
          }
        }
        """.utf8))

        XCTAssertEqual(
            MyInviteCodePresentation(inviteCode: usable, isLoading: false, errorMessage: nil).copyValue,
            "YQMTEST5678"
        )
        XCTAssertEqual(
            MyInviteCodePresentation(inviteCode: nil, isLoading: false, errorMessage: nil).title,
            "暂不可用"
        )
        let forbidden = MyInviteCodePresentation(
            inviteCode: nil,
            isLoading: false,
            errorMessage: "当前账号无权限读取邀请码"
        )
        XCTAssertEqual(forbidden.title, "暂不可读取")
        XCTAssertEqual(forbidden.subtitle, "当前账号无权限读取邀请码")
        XCTAssertNil(forbidden.copyValue)
        XCTAssertFalse(usable.matchesAuthority(tenantID: "tenant-test", imUID: "member-test"))
    }

    func testRemoteGroupDissolvePreviewDecodesCanonicalFields() throws {
        let result = try JSONDecoder().decode(RemoteGroupDissolvePreview.self, from: Data("""
        {
          "group_id": "group-1",
          "member_count": 8,
          "affected_members": 8,
          "confirmation_required": true,
          "confirmation_mode": "button",
          "effects": ["group_hidden", "conversations_removed"]
        }
        """.utf8))

        XCTAssertEqual(result.groupID, "group-1")
        XCTAssertEqual(result.memberCount, 8)
        XCTAssertEqual(result.affectedMembers, 8)
        XCTAssertTrue(result.confirmationRequired)
        XCTAssertEqual(result.confirmationMode, "button")
        XCTAssertEqual(result.effects, ["group_hidden", "conversations_removed"])
    }

    @MainActor
    func testGroupLifecycleErrorCodesUseSafeCopy() {
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_owner_cannot_leave"), "群主需先转让群主或解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "permission_denied"), "只有群主可以解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "confirmation_required"), "请确认后再解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "invalid_confirmation"), "请确认后再解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_already_dissolved"), "该群聊不存在或已解散")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_dissolve_in_progress"), "群聊正在解散中，请稍后")
    }

    @MainActor
    func testTenantLogoRelativeURLResolvesAgainstTenantBase() throws {
        let routeDefaults = UserDefaults(suiteName: "RemoteAPIModelsTests.routes.\(UUID().uuidString)")!
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )

        XCTAssertEqual(
            api.resolveTenantAssetURL("/api/tenant/avatar/file_logo_v2"),
            "https://tenant.example.test/api/tenant/avatar/file_logo_v2"
        )
    }

    @MainActor
    func testTenantLogoRelativeURLResolvesAgainstRuntimeTenantContext() throws {
        let api = IMAPIClient(tenantBase: URL(string: "http://127.0.0.1:5174")!)
        let context = IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: "tenant-a",
            imUID: "WXT000001",
            imToken: "im-token",
            tenantAPIBaseURL: "https://shanghu-a.wenxintong-test.com",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "ios-test-device"
        )

        XCTAssertEqual(
            api.resolveTenantAssetURL("/api/tenant/avatar/file_logo_v2", context: context),
            "https://shanghu-a.wenxintong-test.com/api/tenant/avatar/file_logo_v2"
        )
    }

    func testRemoteTenantIMSessionRefreshResultDecodesTopLevelC2Contract() throws {
        let result = try JSONDecoder().decode(RemoteTenantIMSessionRefreshResult.self, from: Data("""
        {
          "im_token": "new-im-token",
          "expires_at": 1782600000,
          "im_uid": "WXT00000002",
          "tenant_id": "tenant-1",
          "app_id": "jht-ios-main",
          "device_id": "ios-device-1",
          "token_type": "im"
        }
        """.utf8))

        XCTAssertEqual(result.imToken, "new-im-token")
        XCTAssertEqual(result.expiresAt, 1_782_600_000)
        XCTAssertEqual(result.imUID, "WXT00000002")
        XCTAssertEqual(result.tenantID, "tenant-1")
        XCTAssertEqual(result.appID, "jht-ios-main")
        XCTAssertEqual(result.deviceID, "ios-device-1")
        XCTAssertEqual(result.tokenType, "im")
    }

    func testRemoteTenantIMSessionRefreshResultDecodesSessionFallbackWithoutRefreshToken() throws {
        let result = try JSONDecoder().decode(RemoteTenantIMSessionRefreshResult.self, from: Data("""
        {
          "session": {
            "im_token": "session-im-token",
            "expires_at": "1782601234",
            "im_uid": "WXT00000003",
            "app_id": "jht-ios-main",
            "device_id": "ios-device-2"
          },
          "auth_session": {
            "token_type": "im",
            "tenant_id": "tenant-2",
            "app_id": "jht-ios-main",
            "device_id": "ios-device-2",
            "access_expires_at": 1782605678
          }
        }
        """.utf8))

        XCTAssertEqual(result.imToken, "session-im-token")
        XCTAssertEqual(result.expiresAt, 1_782_601_234)
        XCTAssertEqual(result.imUID, "WXT00000003")
        XCTAssertEqual(result.tenantID, "tenant-2")
        XCTAssertEqual(result.appID, "jht-ios-main")
        XCTAssertEqual(result.deviceID, "ios-device-2")
        XCTAssertEqual(result.tokenType, "im")
    }

    func testRemoteTenantProfileDecodesLogoRefreshFields() throws {
        let profile = try JSONDecoder().decode(RemoteTenantProfile.self, from: Data("""
        {
          "tenant_id": "t1",
          "tenant_code": "TEN1",
          "name": "Tenant Renamed",
          "status": "enabled",
          "logo_url": "/api/tenant/avatar/file_logo_v2",
          "logo_status": "ready",
          "logo_version": "logo-v2",
          "logo_updated_at": "2026-06-27T10:00:00Z",
          "logo_cache_key": "logo-v2",
          "logo_mime": "image/png",
          "logo_width": 256,
          "logo_height": 256
        }
        """.utf8))

        XCTAssertEqual(profile.name, "Tenant Renamed")
        XCTAssertEqual(profile.logoURL, "/api/tenant/avatar/file_logo_v2")
        XCTAssertEqual(profile.logoStatus, "ready")
        XCTAssertEqual(profile.logoVersion, "logo-v2")
        XCTAssertEqual(profile.logoCacheKey, "logo-v2")
        XCTAssertEqual(profile.logoWidth, 256)
        XCTAssertEqual(profile.logoHeight, 256)
    }

    func testRemoteTenantLogoObjectKeyOnlyFallsBackToDisplayableStablePath() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenant_code": "WXT123456",
          "name": "测试企业",
          "logo_object_key": "/api/tenant/avatar/file_logo_v3"
        }
        """.utf8))
        let unsafeObjectKey = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-2",
          "tenant_code": "WXT123457",
          "name": "旧对象企业",
          "logo_object_key": "tenant/logo/file_logo_v3.png"
        }
        """.utf8))

        XCTAssertEqual(tenant.logoURL, "/api/tenant/avatar/file_logo_v3")
        XCTAssertEqual(unsafeObjectKey.logoURL, "")
        XCTAssertEqual(unsafeObjectKey.logoCacheKey, "tenant/logo/file_logo_v3.png")
    }

    func testRemoteTenantSearchInviteEntryDecodesInviterDisplay() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenant_code": "WXT123456",
          "name": "测试企业",
          "status": "enabled",
          "entry_type": "member_invite_code",
          "scheme": "unified_v1",
          "canonical": "AB-I00A001",
          "inviter_nickname": "小王"
        }
        """.utf8))
        let enterprise = Enterprise(
            id: tenant.id,
            name: tenant.name,
            code: tenant.tenantCode,
            role: "",
            status: tenant.status,
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            searchEntryType: tenant.entryType,
            searchInviterName: tenant.inviterNickname
        )

        XCTAssertEqual(tenant.entryType, "member_invite_code")
        XCTAssertEqual(tenant.entryScheme, "unified_v1")
        XCTAssertEqual(tenant.entryCanonical, "AB-I00A001")
        XCTAssertEqual(tenant.inviterNickname, "小王")
        XCTAssertEqual(enterprise.searchInviteDisplayLine, "邀请人：小王")
    }

    func testRemoteFileUploadConfigDecodesSplashConfiguration() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "max_mb": 10,
          "source": "tenant.files",
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-1",
          "splash_image_url": "/api/tenant/splash/assets/asset-1",
          "splash_version": "v3",
          "splash_width": "1170",
          "splash_height": 2532,
          "splash_mime_type": "image/png",
          "splash_size_bytes": "2048",
          "splash_etag": "etag-1",
          "splash_sha256": "sha-1",
          "splash_cache_key": "server-cache-v3",
          "splash_cache_strategy": "immutable",
          "splash_min_interval_sec": 3600,
          "splash_daily_cap": 2,
          "splash_min_show_ms": 800,
          "splash_max_show_ms": 3000,
          "splash_action_url": "https://example.test/splash"
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertTrue(splash.licenseEnabled)
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertTrue(splash.splashEnabled)
        XCTAssertEqual(splash.assetID, "asset-1")
        XCTAssertEqual(splash.imageURL, "/api/tenant/splash/assets/asset-1")
        XCTAssertEqual(splash.version, "v3")
        XCTAssertEqual(splash.width, 1170)
        XCTAssertEqual(splash.height, 2532)
        XCTAssertEqual(splash.mimeType, "image/png")
        XCTAssertEqual(splash.sizeBytes, 2048)
        XCTAssertEqual(splash.etag, "etag-1")
        XCTAssertEqual(splash.sha256, "sha-1")
        XCTAssertEqual(splash.cacheKey, "server-cache-v3")
        XCTAssertEqual(splash.cacheStrategy, "immutable")
        XCTAssertEqual(splash.minIntervalSec, 3600)
        XCTAssertEqual(splash.dailyCap, 2)
        XCTAssertEqual(splash.minShowMS, 800)
        XCTAssertEqual(splash.maxShowMS, 3000)
        XCTAssertEqual(splash.actionURL, "https://example.test/splash")
        XCTAssertEqual(splash.disabledReason, "")
    }

    func testRemoteFileUploadConfigDefinesExact500MiBBoundary() throws {
        let serverLimit = Int64(500 * 1024 * 1024)
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": \(serverLimit),
          "max_mb": 500,
          "source": "tenant.license"
        }
        """.utf8)).model

        XCTAssertEqual(config.maxBytes, serverLimit)
        XCTAssertEqual(config.source, "tenant.license")
        XCTAssertTrue(config.allowsUpload(sizeBytes: serverLimit))
        XCTAssertFalse(config.allowsUpload(sizeBytes: serverLimit + 1))
    }

    func testRemoteFileUploadConfigDecodesNestedDisabledSplashConfiguration() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "max_bytes": 1024,
          "features": {
            "splash_enabled": false,
            "splash_license_enabled": false,
            "splash_config_enabled": false
          },
          "splash": {
            "asset_id": "asset-disabled",
            "image_url": "/api/tenant/splash/assets/asset-disabled",
            "version": "v1"
          }
        }
        """.utf8))

        XCTAssertFalse(config.splashConfiguration.licenseEnabled)
        XCTAssertEqual(config.splashConfiguration.configEnabled, false)
        XCTAssertFalse(config.splashConfiguration.splashEnabled)
        XCTAssertEqual(config.splashConfiguration.assetID, "asset-disabled")
        XCTAssertEqual(config.splashConfiguration.disabledReason, "license_disabled")
    }

    func testRemoteFileUploadConfigDecodesStage4SplashAliasesAndIgnoresUploadLimits() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-stage4",
          "splash_image_url": "/api/tenant/splash/assets/asset-stage4",
          "splash_version": "v4",
          "splash_cache_key": "tenant-1/asset-stage4/v4",
          "splash_cache_strategy": "asset_version",
          "splash_upload_limits": {
            "max_bytes": 5242880,
            "min_width": 720,
            "min_height": 1280,
            "allowed_mime_types": ["image/jpeg", "image/png", "image/webp"]
          }
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertTrue(splash.licenseEnabled)
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertTrue(splash.splashEnabled)
        XCTAssertEqual(splash.assetID, "asset-stage4")
        XCTAssertEqual(splash.cacheKey, "tenant-1/asset-stage4/v4")
        XCTAssertEqual(splash.cacheStrategy, "asset_version")
        XCTAssertEqual(splash.disabledReason, "")

        let snapshot = splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-stage4",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(snapshot.cacheKey, SplashImageDiskCache.cacheKey(explicitKey: "tenant-1/asset-stage4/v4"))
    }

    func testRemoteFileUploadConfigDecodesNumericSplashVersionFromRealPayloadShape() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "custom_splash_enabled": true,
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_config_enabled": true,
          "splash_disabled_reason": "",
          "splash_asset_id": "da2476ad-38d6-48a6-964b-650672cc18e9",
          "splash_image_url": "/api/tenant/splash/assets/da2476ad-38d6-48a6-964b-650672cc18e9",
          "splash_version": 1,
          "splash_cache_key": "da2476ad-38d6-48a6-964b-650672cc18e9:1"
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertEqual(splash.version, "1")
        XCTAssertEqual(splash.disabledReason, "")

        let snapshot = splash.makeSnapshot(
            tenantID: "tenant-real",
            resolvedImageURL: "http://127.0.0.1:8080/api/tenant/splash/assets/da2476ad-38d6-48a6-964b-650672cc18e9",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(snapshot.isConfigDisplayable)
        XCTAssertEqual(
            snapshot.cacheKey,
            SplashImageDiskCache.cacheKey(explicitKey: "da2476ad-38d6-48a6-964b-650672cc18e9:1")
        )
        XCTAssertNotEqual(snapshot.disabledReason, "missing_version")
    }

    func testRemoteFileUploadConfigDecodesStage4SplashDisabledReason() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-deleted",
          "splash_image_url": "/api/tenant/splash/assets/asset-deleted",
          "splash_version": "v5",
          "splash_disabled_reason": "asset_deleted"
        }
        """.utf8))

        XCTAssertEqual(config.splashConfiguration.disabledReason, "asset_deleted")
        let snapshot = config.splashConfiguration.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-deleted"
        )
        XCTAssertFalse(snapshot.isConfigDisplayable)
        XCTAssertEqual(snapshot.disabledReason, "asset_deleted")
    }

    func testRemoteFileUploadConfigFailsClosedWhenSplashConfigFlagIsMissing() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_asset_id": "asset-missing-config",
          "splash_image_url": "/api/tenant/splash/assets/asset-missing-config",
          "splash_version": 1
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertNil(splash.configEnabled)
        XCTAssertEqual(splash.disabledReason, "splash_config_missing")
        XCTAssertFalse(splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-missing-config"
        ).isConfigDisplayable)
    }

    func testRemoteFileUploadConfigFailsClosedWhenSplashConfigIsDisabled() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_config_enabled": false,
          "splash_asset_id": "asset-disabled-config",
          "splash_image_url": "/api/tenant/splash/assets/asset-disabled-config",
          "splash_version": 1
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertEqual(splash.configEnabled, false)
        XCTAssertEqual(splash.disabledReason, "splash_config_disabled")
        XCTAssertFalse(splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-disabled-config"
        ).isConfigDisplayable)
    }

    func testTenantModelsDecodeCamelCaseTenantNameAndCode() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled"
        }
        """.utf8))
        let workspace = try JSONDecoder().decode(RemoteWorkspaceTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled",
          "can_switch": true
        }
        """.utf8))
        let profile = try JSONDecoder().decode(RemoteTenantProfile.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled"
        }
        """.utf8))

        XCTAssertEqual(tenant.tenantCode, "WXT123456")
        XCTAssertEqual(tenant.name, "后台改名企业")
        XCTAssertEqual(workspace.tenantCode, "WXT123456")
        XCTAssertEqual(workspace.name, "后台改名企业")
        XCTAssertEqual(profile.tenantCode, "WXT123456")
        XCTAssertEqual(profile.name, "后台改名企业")
    }

    func testRemoteMessageDecodesAliasesAndPayloadFallbacks() throws {
        let json = """
        {
          "id": "msg-1",
          "client_id": "client-1",
            "payload": {
              "channel_id": "direct-u1-u2",
              "channel_type": "direct",
              "from_uid": "u1",
              "sender_name": "Alice",
              "sender_avatar_url": "https://example.test/a.png",
              "sender_avatar_version": "v7",
              "sender_avatar_updated_at": "2026-06-26T01:00:00Z",
              "content_type": "text",
              "client_msg_no": "payload-client"
            },
          "seq": 42,
          "quoted_text": "previous",
          "status": "sent",
          "read_status": "read",
          "read_count": 3,
          "read_at": "2026-06-23T01:02:03Z",
          "created_at": "2026-06-23T01:00:00Z"
        }
        """

        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.messageID, "msg-1")
        XCTAssertEqual(message.clientMsgNo, "client-1")
        XCTAssertEqual(message.channelID, "direct-u1-u2")
        XCTAssertEqual(message.channelType, "direct")
        XCTAssertEqual(message.channelSeq, 42)
        XCTAssertEqual(message.fromUID, "u1")
        XCTAssertEqual(message.senderProvenance, .clientSupplied)
        XCTAssertEqual(message.senderDisplayName, "Alice")
        XCTAssertEqual(message.senderAvatar, "https://example.test/a.png")
        XCTAssertEqual(message.senderAvatarVersion, "v7")
        XCTAssertEqual(message.senderAvatarUpdatedAt, "2026-06-26T01:00:00Z")
        XCTAssertEqual(message.contentType, "text")
        XCTAssertEqual(message.quote, "previous")
        XCTAssertEqual(message.readCount, 3)
    }

    func testRemoteMessageSenderProvenanceRequiresStoredTopLevelSender() throws {
        let authoritative = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "stored-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 7,
          "sender_uid": "actor-1",
          "content_type": "voice",
          "payload": {"sender_uid": "spoofed-actor"},
          "created_at": "2026-07-28T01:00:00Z"
        }
        """.utf8))
        let payloadOnly = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "payload-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 8,
          "content_type": "voice",
          "payload": {"sender_uid": "actor-1"},
          "created_at": "2026-07-28T01:00:01Z"
        }
        """.utf8))
        let missing = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "missing-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 9,
          "content_type": "voice",
          "payload": {},
          "created_at": "2026-07-28T01:00:02Z"
        }
        """.utf8))

        XCTAssertEqual(authoritative.fromUID, "actor-1")
        XCTAssertEqual(authoritative.senderProvenance, .authoritativeStored)
        XCTAssertEqual(payloadOnly.fromUID, "actor-1")
        XCTAssertEqual(payloadOnly.senderProvenance, .clientSupplied)
        XCTAssertEqual(missing.fromUID, "")
        XCTAssertEqual(missing.senderProvenance, .unknown)
    }

    func testRemoteMessageDecodesEditedStatusAndAliases() throws {
        let statusEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 8,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {"text": "updated text"},
          "status": "edited",
          "created_at": "2026-06-23T01:00:00Z"
        }
        """.utf8))
        let payloadEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-2",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 9,
          "from_uid": "u2",
          "content_type": "text",
          "payload": {"text": "new text", "edited_at": "2026-06-23T01:01:00Z"},
          "status": "sent"
        }
        """.utf8))
        let boolEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-3",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 10,
          "from_uid": "u3",
          "content_type": "text",
          "payload": {"text": "new text"},
          "is_edited": true,
          "status": "sent"
        }
        """.utf8))

        XCTAssertTrue(statusEdited.isEdited)
        XCTAssertTrue(payloadEdited.isEdited)
        XCTAssertTrue(boolEdited.isEdited)
    }

    func testRemoteAttachmentNameDoesNotBecomeSenderDisplayName() throws {
        let json = """
        {
          "message_id": "msg-file-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 43,
          "from_uid": "u2",
          "content_type": "file",
          "payload": {
            "file_id": "file-1",
            "file_name": "frontend-slides-main.zip",
            "name": "frontend-slides-main.zip",
            "media_category": "archive"
          },
          "status": "sent",
          "created_at": "2026-06-23T01:01:00Z"
        }
        """

        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.senderDisplayName, "")
        XCTAssertEqual(message.payload["name"]?.stringValue, "frontend-slides-main.zip")
    }

    func testRemoteConversationDecodesDisplayAndUnreadFallbacks() throws {
        let json = """
        {
          "channel_id": "group-1",
          "channel_type": "group",
          "unread_count": 5,
          "unread_reaction_count": 2,
          "has_reaction_unread": "true",
          "last_msg_seq": 100,
          "last_read": 80,
          "first_unread_seq": 81,
          "version": 7,
          "pinned": true,
          "mute": true,
          "displayName": "Design Group",
          "last_message": {
            "message_id": "msg-2",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 100,
            "from_uid": "u2",
            "sender_display_name": "Bob",
            "content_type": "text",
            "payload": {"text": "hello"},
            "status": "sent"
          },
          "pinned_messages": [],
          "has_mention": true,
          "mention_count": 1,
          "mention_summary": {
            "type": "mention",
            "text": "@you",
            "message_id": "msg-2",
            "channel_seq": 100
          }
        }
        """

        let conversation = try JSONDecoder().decode(RemoteConversation.self, from: Data(json.utf8))

        XCTAssertEqual(conversation.channelID, "group-1")
        XCTAssertEqual(conversation.displayName, "Design Group")
        XCTAssertEqual(conversation.lastReadSeq, 80)
        XCTAssertEqual(conversation.unreadAnchorSeq, 81)
        XCTAssertEqual(conversation.unreadAnchorState, "ready")
        XCTAssertTrue(conversation.stick)
        XCTAssertTrue(conversation.mute)
        XCTAssertTrue(conversation.hasReactionUnread)
        XCTAssertEqual(conversation.lastMessage?.messageID, "msg-2")
        XCTAssertTrue(conversation.pinnedMessagesProvided)
        XCTAssertEqual(conversation.mentionSummary?.messageID, "msg-2")
    }

    func testRemoteConversationSyncDecodesMultiplePinnedAliases() throws {
        let json = """
        {
          "version": 9,
          "conversations": [
            {
              "channel_id": "stick-only",
              "channel_type": "group",
              "pinned": false,
              "stick": true,
              "mute": false,
              "muted": true,
              "display_name": "Stick Only"
            },
            {
              "channel_id": "is-pinned",
              "channel_type": "group",
              "is_pinned": true,
              "dnd": "true",
              "display_name": "Is Pinned"
            },
            {
              "channel_id": "sticky",
              "channel_type": "group",
              "sticky": 1,
              "is_muted": 1,
              "display_name": "Sticky"
            },
            {
              "channel_id": "top",
              "channel_type": "group",
              "top": "true",
              "doNotDisturb": true,
              "display_name": "Top"
            },
            {
              "channel_id": "regular",
              "channel_type": "group",
              "pinned": false,
              "stick": false,
              "mute": false,
              "muted": false,
              "dnd": false,
              "display_name": "Regular"
            }
          ]
        }
        """

        let sync = try JSONDecoder().decode(RemoteConversationSyncData.self, from: Data(json.utf8))

        XCTAssertEqual(
            sync.conversations.filter(\.stick).map(\.channelID),
            ["stick-only", "is-pinned", "sticky", "top"]
        )
        XCTAssertEqual(
            sync.conversations.filter(\.mute).map(\.channelID),
            ["stick-only", "is-pinned", "sticky", "top"]
        )
        XCTAssertFalse(sync.conversations.first { $0.channelID == "regular" }?.stick ?? true)
        XCTAssertFalse(sync.conversations.first { $0.channelID == "regular" }?.mute ?? true)
    }

    func testRemoteGroupDecodesMemberCountAliases() throws {
        let group = try JSONDecoder().decode(RemoteUserGroup.self, from: Data("""
        {
          "group_id": "g1",
          "name": "交易通知群",
          "totalMembers": "91",
          "my_role": "member"
        }
        """.utf8))
        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "交易通知群",
            "membersTotal": 80,
            "my_role": "member"
          },
          "member_num": "91"
        }
        """.utf8))
        let list = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data("""
        {
          "items": [],
          "total_count": "91"
        }
        """.utf8))

        XCTAssertEqual(group.memberCount, 91)
        XCTAssertEqual(detail.memberCount, 91)
        XCTAssertEqual(list.total, 91)
    }

    func testRemoteFriendRelationDecodesPresenceWithoutDefaultingOnline() throws {
        let offline = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-offline",
          "friend_user_id": "WXT000001",
          "friend_nickname": "离线用户"
        }
        """.utf8))
        XCTAssertEqual(offline.friendStatus, "")
        XCTAssertFalse(offline.friendOnline)

        let online = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-online",
          "friend_user_id": "WXT000002",
          "friend_nickname": "在线用户",
          "friend_status": "online",
          "is_online": "true"
        }
        """.utf8))
        XCTAssertEqual(online.friendStatus, "online")
        XCTAssertTrue(online.friendOnline)
    }

    func testRemoteFriendRelationKeepsAuthoritativeFriendUIDSeparateFromCompatibilityFallbacks() throws {
        let canonical = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "im-canonical-1",
          "friend_user_id": "WXT000001",
          "peer_uid": "legacy-peer"
        }
        """.utf8))
        XCTAssertEqual(canonical.friendUID, "im-canonical-1")
        XCTAssertEqual(canonical.authoritativeFriendUID, "im-canonical-1")
        XCTAssertEqual(canonical.authoritativeFriendUserID, "WXT000001")

        let compatibilityOnly = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_user_id": "WXT000002",
          "peer_uid": "legacy-peer"
        }
        """.utf8))
        XCTAssertEqual(compatibilityOnly.friendUID, "WXT000002")
        XCTAssertNil(compatibilityOnly.authoritativeFriendUID)
        XCTAssertEqual(compatibilityOnly.authoritativeFriendUserID, "WXT000002")
    }

    func testPresenceStatusDecodingKeepsExplicitAuthoritySeparateFromCompatibilityFields() throws {
        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "friend-1",
          "presence_status": "offline",
          "friend_status": "online",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(relation.friendStatus, "offline")
        XCTAssertTrue(relation.friendOnline)
        XCTAssertTrue(relation.friendOnlineKnown)

        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "member-1",
          "status": "cancelled",
          "presence_status": "online",
          "online": false
        }
        """.utf8))
        XCTAssertEqual(member.status, "cancelled")
        XCTAssertEqual(member.presenceStatus, "online")
        XCTAssertFalse(member.online)
        XCTAssertTrue(member.onlineKnown)

        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "user-1",
          "status": "enabled",
          "presence_status": "away",
          "is_online": false
        }
        """.utf8))
        XCTAssertEqual(user.status, "enabled")
        XCTAssertEqual(user.presenceStatus, "away")
        XCTAssertFalse(user.online)
        XCTAssertTrue(user.onlineKnown)

        let me = try JSONDecoder().decode(RemoteMeProfile.self, from: Data("""
        {
          "im_uid": "viewer-1",
          "status": "enabled",
          "presence_status": "busy",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(me.status, "enabled")
        XCTAssertEqual(me.presenceStatus, "busy")
        XCTAssertTrue(me.online)

        let organizationMember = try JSONDecoder().decode(RemoteOrganizationMemberView.self, from: Data("""
        {
          "im_uid": "organization-1",
          "status": "enabled",
          "presence_status": "dnd",
          "isOnline": true
        }
        """.utf8))
        XCTAssertEqual(organizationMember.status, "enabled")
        XCTAssertEqual(organizationMember.presenceStatus, "dnd")
        XCTAssertTrue(organizationMember.online)

        let searchItem = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "search-1",
          "status": "cancelled",
          "presence_status": "hidden",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(searchItem.status, "cancelled")
        XCTAssertEqual(searchItem.presenceStatus, "hidden")
        XCTAssertTrue(searchItem.online)

        let searchItemWithoutPresence = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "search-2",
          "status": "cancelled",
          "online": false
        }
        """.utf8))
        XCTAssertEqual(searchItemWithoutPresence.status, "cancelled")
        XCTAssertEqual(searchItemWithoutPresence.presenceStatus, "")
        XCTAssertFalse(searchItemWithoutPresence.online)
        XCTAssertTrue(searchItemWithoutPresence.onlineKnown)

        let memberWithoutPresence = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "member-2",
          "status": "cancelled",
          "is_online": true
        }
        """.utf8))
        XCTAssertEqual(memberWithoutPresence.status, "cancelled")
        XCTAssertEqual(memberWithoutPresence.presenceStatus, "")
        XCTAssertTrue(memberWithoutPresence.online)
        XCTAssertTrue(memberWithoutPresence.onlineKnown)
    }

    func testRemoteFriendRelationDecodesRemarkDisplayFieldsSeparately() throws {
        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-remarked",
          "friend_user_id": "WXT000003",
          "friend_nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总"
        }
        """.utf8))

        XCTAssertEqual(relation.friendNickname, "原始昵称")
        XCTAssertEqual(relation.rawNickname, "原始昵称")
        XCTAssertEqual(relation.displayName, "客户王总")
        XCTAssertEqual(relation.displayNameSource, "remark")
        XCTAssertEqual(relation.remark, "客户王总")
    }

    func testRemoteUserSearchItemDecodesRemarkDisplayFieldsSeparately() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "u-search",
          "user_id": "WXT000004",
          "nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总"
        }
        """.utf8))

        XCTAssertEqual(item.nickname, "原始昵称")
        XCTAssertEqual(item.rawNickname, "原始昵称")
        XCTAssertEqual(item.displayName, "客户王总")
        XCTAssertEqual(item.displayNameSource, "remark")
        XCTAssertEqual(item.remark, "客户王总")
    }

    func testRemoteUserSearchItemDecodesFriendRelationV2Contract() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "internal-1",
          "user_id": "WXTAB123456",
          "nickname": "内部用户",
          "relation_status": "none",
          "can_apply_friend": true,
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))

        XCTAssertEqual(item.relationStatus, "none")
        XCTAssertTrue(item.canApplyFriend)
        XCTAssertEqual(item.friendAction, "request")
        XCTAssertEqual(item.friendFlow, "ordinary_to_internal")
        XCTAssertEqual(item.requiresTenantReview, false)
        XCTAssertEqual(item.requiresTargetApproval, false)
    }

    func testRemoteUserSearchItemLegacyResponseDerivesFriendAction() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "legacy-1",
          "user_id": "WXT00000001",
          "nickname": "旧服务端用户",
          "can_apply_friend": true
        }
        """.utf8))

        XCTAssertEqual(item.friendAction, "request")
        XCTAssertEqual(item.friendFlow, "")
        XCTAssertNil(item.requiresTenantReview)
        XCTAssertNil(item.requiresTargetApproval)
    }

    func testRemoteFriendApplyResultDecodesSuppressedAndEstablishedOutcomes() throws {
        let suppressed = try JSONDecoder().decode(RemoteFriendApplyResult.self, from: Data("""
        {
          "application_id": "application-1",
          "status": "suppressed",
          "outcome": "application_suppressed",
          "relation_status": "history",
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "directly_established": false,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))
        let established = try JSONDecoder().decode(RemoteFriendApplyResult.self, from: Data("""
        {
          "id": "relation-1",
          "status": "accepted",
          "outcome": "friendship_established",
          "relation_status": "friend",
          "friend_action": "direct_add",
          "friend_flow": "internal_direct",
          "directly_established": true,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))

        XCTAssertEqual(suppressed.id, "application-1")
        XCTAssertEqual(suppressed.outcome, "application_suppressed")
        XCTAssertEqual(suppressed.friendFlow, "ordinary_to_internal")
        XCTAssertFalse(suppressed.directlyEstablished)
        XCTAssertEqual(suppressed.relationStatus, "history")
        XCTAssertEqual(AppState.friendApplyResolution(suppressed), .terminal)
        XCTAssertEqual(established.outcome, "friendship_established")
        XCTAssertEqual(established.relationStatus, "friend")
        XCTAssertEqual(established.friendAction, "direct_add")
        XCTAssertTrue(established.directlyEstablished)
        XCTAssertEqual(AppState.friendApplyResolution(established), .established)
    }

    func testRemoteFriendApplicationAndErrorDecodeV2FriendMetadata() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-2",
          "applicant_uid": "ordinary-1",
          "target_uid": "internal-1",
          "status": "suppressed",
          "direction": "outgoing",
          "outcome": "application_suppressed",
          "relation_status": "history",
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "directly_established": false,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))
        let error = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data("""
        {
          "ok": false,
          "code": "not_friends",
          "data": {
            "target_uid": "ordinary-2",
            "can_apply_friend": true,
            "relation_status": "none",
            "friend_action": "request",
            "friend_flow": "internal_direct"
          }
        }
        """.utf8))

        XCTAssertEqual(application.outcome, "application_suppressed")
        let projected = try XCTUnwrap(AppState.friendRequestProjection(application, currentID: "ordinary-1"))
        XCTAssertEqual(projected.status, "suppressed")
        XCTAssertEqual(projected.relationStatus, "history")
        XCTAssertEqual(projected.message, FriendAddPresentation.suppressedMessage)
        XCTAssertEqual(projected.statusLabel, "未投递")
        XCTAssertFalse(projected.isPendingOutgoing)
        XCTAssertFalse(projected.canCancel)
        XCTAssertFalse(projected.accepted)
        XCTAssertEqual(application.friendFlow, "ordinary_to_internal")
        XCTAssertEqual(application.requiresTargetApproval, false)
        XCTAssertEqual(error.resolvedError?.friendRequestStatus, "none")
        XCTAssertEqual(error.resolvedError?.friendAction, "request")
        XCTAssertEqual(error.resolvedError?.friendFlow, "internal_direct")
    }

    func testFriendProjectionTrustsViewerActionableAndServerDirectionOverGenericHints() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-actionable",
          "applicant_uid": "ordinary-peer",
          "target_uid": "internal-current",
          "applicant_name": "申请人",
          "status": "pending",
          "direction": "incoming",
          "actionable_by_current_user": true,
          "tenant_review_status": "not_required",
          "requires_target_approval": false
        }
        """.utf8))

        let projected = try XCTUnwrap(
            AppState.friendRequestProjection(application, currentID: "internal-current")
        )
        XCTAssertEqual(projected.direction, "incoming")
        XCTAssertTrue(projected.canRespond)
        XCTAssertTrue(projected.isPendingIncoming)
    }

    func testFriendProjectionUsesIdentityDirectionOnlyForLegacyPayload() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-legacy",
          "applicant_uid": "ordinary-peer",
          "target_uid": "internal-current",
          "status": "pending",
          "tenant_review_status": "approved",
          "requires_target_approval": true
        }
        """.utf8))

        let projected = try XCTUnwrap(
            AppState.friendRequestProjection(application, currentID: "internal-current")
        )
        XCTAssertEqual(projected.direction, "incoming")
        XCTAssertTrue(projected.canRespond)
    }

    func testRemoteGroupMemberMissingPresenceStaysOfflineByDefault() throws {
        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "u1",
          "nickname": "Alice",
          "role": "member"
        }
        """.utf8))

        XCTAssertEqual(member.status, "")
        XCTAssertFalse(member.online)
    }

    func testRemoteGroupMemberDecodesRemarkDisplayFieldsSeparately() throws {
        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "u-member",
          "user_id": "WXT000005",
          "nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "group_nickname": "群名片",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总",
          "role": "member"
        }
        """.utf8))

        XCTAssertEqual(member.nickname, "原始昵称")
        XCTAssertEqual(member.rawNickname, "原始昵称")
        XCTAssertEqual(member.groupNickname, "群名片")
        XCTAssertEqual(member.displayName, "客户王总")
        XCTAssertEqual(member.displayNameSource, "remark")
        XCTAssertEqual(member.remark, "客户王总")
    }

    func testRemoteGroupSummaryDecodesSlimContract() throws {
        let summary = try JSONDecoder().decode(RemoteGroupSummary.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "全员公告群",
            "member_count": 503,
            "my_role": "member"
          },
          "my_role": "admin",
          "counts": {
            "member_count": "503",
            "admin_count": 6,
            "pendingJoinRequestCount": "2",
            "fileCount": 4
          },
          "member_preview": [
            {
              "im_uid": "u1",
              "nickname": "群主",
              "role": "owner",
              "is_owner": true
            }
          ],
          "settings": {
            "invite_confirm_required": true,
            "file_count": 4
          }
        }
        """.utf8))

        XCTAssertEqual(summary.summary.groupID, "g1")
        XCTAssertEqual(summary.myRole, "admin")
        XCTAssertEqual(summary.memberCount, 503)
        XCTAssertEqual(summary.counts.pendingJoinRequestCount, 2)
        XCTAssertEqual(summary.counts.fileCount, 4)
        XCTAssertEqual(summary.memberPreview.first?.imUID, "u1")
        XCTAssertFalse(summary.isMemberPreviewComplete)
        XCTAssertTrue(summary.settings.inviteConfirmRequired)
    }

    func testRemoteListDecodesMembersPaginationFields() throws {
        let list = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data("""
        {
          "items": [
            {
              "im_uid": "u1",
              "nickname": "Alice",
              "role": "member"
            }
          ],
          "self_member": {
            "im_uid": "self-1",
            "nickname": "全局昵称",
            "group_nickname": "我的群昵称",
            "role": "member",
            "revision": 9,
            "group_membership_generation": 12
          },
          "total_count": "503",
          "limit": "120",
          "offset": 20,
          "hasMore": "true",
          "nextOffset": "140"
        }
        """.utf8))

        XCTAssertEqual(list.items.map(\.imUID), ["u1"])
        XCTAssertEqual(list.selfMember?.imUID, "self-1")
        XCTAssertEqual(list.selfMember?.groupNickname, "我的群昵称")
        XCTAssertEqual(list.selfMember?.groupMembershipGeneration, 12)
        XCTAssertEqual(list.total, 503)
        XCTAssertEqual(list.limit, 120)
        XCTAssertEqual(list.offset, 20)
        XCTAssertEqual(list.hasMore, true)
        XCTAssertEqual(list.nextOffset, 140)
    }

    func testRemoteGroupDecodesInviteConfirmRequiredAliasesWithPriority() throws {
        let camelGroup = try JSONDecoder().decode(RemoteUserGroup.self, from: Data("""
        {
          "group_id": "g1",
          "name": "审批群",
          "inviteConfirmRequired": true
        }
        """.utf8))
        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "审批群"
          },
          "settings": {
            "invite_confirm_required": false,
            "inviteConfirmRequired": true,
            "approval": true
          }
        }
        """.utf8))

        XCTAssertTrue(camelGroup.inviteConfirmRequired)
        XCTAssertFalse(detail.settings.inviteConfirmRequired)
    }

    func testRemoteVerificationStatusKeepsMaskedPresentationWithoutTreatingItAsProof() throws {
        let status = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data("""
        {
          "im_uid": "WXT00000002",
          "account_id": "admin2",
          "phone_masked": "138****1001",
          "real_name_verified": false,
          "real_name_status": "unsubmitted"
        }
        """.utf8))

        XCTAssertFalse(status.phoneBound)
        XCTAssertFalse(status.phoneBindingKnown)
        XCTAssertEqual(status.phoneMasked, "138****1001")
        XCTAssertNil(status.phoneRequirementSatisfied)
        XCTAssertNil(status.realNameRequirementSatisfied)
    }

    func testBackendCreatedOrdinaryAndInternalUsersUseOnlyMatchedRequirementBooleans() throws {
        for (imUID, localID) in [
            ("ordinary-created-by-admin", "ordinary-created-by-admin"),
            ("internal-created-by-admin", "internal-local-record")
        ] {
            let status = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data("""
            {
              "im_uid": "\(imUID)",
              "phone_requirement_satisfied": true,
              "real_name_requirement_satisfied": true,
              "phone_masked": "138****1001",
              "real_name_masked": "张*",
              "real_name_status": "approved"
            }
            """.utf8))
            let user = makeForcedAuthUser(
                id: localID,
                userID: imUID,
                realNameVerified: false,
                realNameStatus: "unsubmitted",
                phoneVerified: false
            )

            let projection = verificationRequirementAuthorityProjection(
                status: status,
                currentUser: user
            )

            XCTAssertEqual(projection?.phoneSatisfied, true)
            XCTAssertEqual(projection?.realNameSatisfied, true)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteVerificationStatus.self,
                from: Data(#"{"im_uid":"ordinary-created-by-admin","phone_requirement_satisfied":"true","real_name_requirement_satisfied":true}"#.utf8)
            )
        )
    }

    func testVerificationRequirementAuthorityFailsClosedForFalseMissingAndCrossUserPayloads() throws {
        let user = makeForcedAuthUser(
            id: "uid-current",
            realNameVerified: true,
            realNameStatus: "approved",
            phoneVerified: true
        )
        let explicitFalse = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-current","phone_requirement_satisfied":false,"real_name_requirement_satisfied":false}"#.utf8))
        let missing = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-current","phone_masked":"138****1001","real_name_status":"approved"}"#.utf8))
        let crossUser = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-other","phone_requirement_satisfied":true,"real_name_requirement_satisfied":true}"#.utf8))

        XCTAssertEqual(
            verificationRequirementAuthorityProjection(status: explicitFalse, currentUser: user),
            VerificationRequirementAuthorityProjection(phoneSatisfied: false, realNameSatisfied: false)
        )
        XCTAssertEqual(
            verificationRequirementAuthorityProjection(status: missing, currentUser: user),
            VerificationRequirementAuthorityProjection(phoneSatisfied: false, realNameSatisfied: false)
        )
        XCTAssertNil(verificationRequirementAuthorityProjection(status: crossUser, currentUser: user))
    }

    func testRemoteIMUserDecodesMaskedPhoneAsVerifiedSnapshot() throws {
        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "WXT00000002",
          "user_id": "WXT00000002",
          "account_id": "admin2",
          "nickname": "admin2",
          "phone_masked": "138****1001"
        }
        """.utf8))

        XCTAssertEqual(user.phone, "138****1001")
        XCTAssertTrue(user.phoneVerified)
    }

    func testRemoteAuthDataDecodesTenantMemberDefaultAvatar() throws {
        let data = try JSONDecoder().decode(RemoteAuthData.self, from: Data("""
        {
          "account": {
            "id": "acct-1",
            "username": "admin13",
            "phone": "",
            "status": "normal"
          },
          "platform_token": "platform-token",
          "tenant": {
            "id": "tenant-1",
            "tenant_code": "WXT000001",
            "name": "Default Enterprise",
            "status": "enabled"
          },
          "tenant_member": {
            "id": "tm-1",
            "tenant_id": "tenant-1",
            "account_id": "acct-1",
            "im_uid": "WXT56697668",
            "nickname": "admin13",
            "avatar": "/api/tenant/static/avatars/default-users/user-default-avatar-07.png",
            "avatar_version": "default-user-avatar-07",
            "avatar_updated_at": "2026-06-27T00:00:00Z",
            "status": "normal",
            "role": "member"
          }
        }
        """.utf8))

        let member = try XCTUnwrap(data.tenantMember)
        XCTAssertEqual(member.avatar, "/api/tenant/static/avatars/default-users/user-default-avatar-07.png")
        XCTAssertEqual(member.avatarVersion, "default-user-avatar-07")
        XCTAssertEqual(member.avatarUpdatedAt, "2026-06-27T00:00:00Z")
    }

    func testRemoteUserStickerManifestDecodesProcessingFieldsAndVariants() throws {
        let list = try JSONDecoder().decode(RemoteList<RemoteUserSticker>.self, from: Data("""
        {
          "items": [
            {
              "id": "us-1",
              "sticker_id": "st-1",
              "file_id": "file-1",
              "status": "active",
              "processing_status": "active",
              "sort": "7",
              "mime_type": "image/gif",
              "size_bytes": "12345",
              "width": "240",
              "height": 180,
              "duration_ms": "900",
              "frame_count": "12",
              "cache_key": "cache-1",
              "version": "v3",
              "thumbnail_url": "/api/tenant/files/file-1/thumbnail",
              "variants": [
                {
                  "kind": "thumb",
                  "file_id": "thumb-1",
                  "mime_type": "image/png",
                  "url": "/api/tenant/files/thumb-1/presigned-preview",
                  "size_bytes": "512",
                  "width": "96",
                  "height": "96",
                  "cache_key": "thumb-cache"
                }
              ],
              "created_at": "2026-06-26T01:00:00Z",
              "updated_at": "2026-06-26T01:02:00Z"
            }
          ],
          "total": 1
        }
        """.utf8))

        let sticker = try XCTUnwrap(list.items.first)
        XCTAssertEqual(sticker.id, "us-1")
        XCTAssertEqual(sticker.stickerID, "st-1")
        XCTAssertEqual(sticker.sizeBytes, 12_345)
        XCTAssertEqual(sticker.width, 240)
        XCTAssertEqual(sticker.durationMS, 900)
        XCTAssertEqual(sticker.frameCount, 12)
        XCTAssertEqual(sticker.variants.first?.kind, "thumb")
        XCTAssertEqual(sticker.variants.first?.url, "/api/tenant/files/thumb-1/presigned-preview")
        XCTAssertEqual(sticker.variants.first?.sizeBytes, 512)
    }

    func testRemoteStickerMessageDecodesContentTypeAndSnapshotPayload() throws {
        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-sticker-1",
          "channel_id": "g1",
          "channel_type": "group",
          "channel_seq": 88,
          "from_uid": "uid-2",
          "content_type": "sticker",
          "payload": {
            "type": "sticker",
            "sticker_id": "st-1",
            "pack_id": "pack-1",
            "file_id": "file-1",
            "mime_type": "image/gif",
            "width": 240,
            "height": 180,
            "duration_ms": 900,
            "frame_count": 12,
            "thumbnail_url": "/assets/sticker-thumb.png",
            "fallback_text": "[GIF表情]",
            "variants": [
              {
                "kind": "original",
                "file_id": "file-1",
                "mime_type": "image/gif",
                "cache_key": "gif-v1",
                "thumbnail_url": "/assets/sticker.gif"
              }
            ]
          },
          "status": "sent",
          "created_at": "2026-06-26T02:00:00Z"
        }
        """.utf8))

        XCTAssertEqual(message.contentType, "sticker")
        XCTAssertEqual(message.payload["type"]?.stringValue, "sticker")
        XCTAssertEqual(message.payload["sticker_id"]?.stringValue, "st-1")
        XCTAssertEqual(message.payload["fallback_text"]?.stringValue, StickerMessageSnapshot.fallbackText)
        guard case .array(let variants)? = message.payload["variants"],
              case .object(let first)? = variants.first else {
            return XCTFail("Expected sticker variants")
        }
        XCTAssertEqual(first["kind"]?.stringValue, "original")
        XCTAssertEqual(first["cache_key"]?.stringValue, "gif-v1")
    }

    func testStickerGIFRendererUsesImageIOWithoutWebViewOrUIImageDataPlayback() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM/StickerGIFRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import ImageIO"))
        XCTAssertTrue(source.contains("CGImageSourceCreateWithData"))
        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        XCTAssertFalse(source.contains("WKWebView"))
        XCTAssertFalse(source.contains("UIImage(data:"))
    }

	    func testStickerMessageViewResolvesTenantFilePayloadsBeforeRendering() throws {
	        let testFile = URL(fileURLWithPath: #filePath)
	        let appSourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM")
        let appStateSource = try String(contentsOf: appSourceRoot.appendingPathComponent("AppState.swift"), encoding: .utf8)
        let chatViewsSource = try String(contentsOf: appSourceRoot.appendingPathComponent("ChatViews.swift"), encoding: .utf8)

        XCTAssertTrue(appStateSource.contains("func resolveStickerMessageAssetsIfNeeded(for snapshot: StickerMessageSnapshot?)"))
        XCTAssertTrue(appStateSource.contains("api.getTenantFile(context: context, fileID: fileID)"))
        XCTAssertTrue(appStateSource.contains("stickerMessageFileURL(for: snapshot, preferThumbnail: false)"))
        XCTAssertTrue(appStateSource.contains("downloadStickerMessageAssetToLocalFile"))
        XCTAssertTrue(appStateSource.contains("file.localDownloadURL"))
        XCTAssertTrue(appStateSource.contains("thumbnail_file_id"))
	        XCTAssertTrue(chatViewsSource.contains("state.resolveStickerMessageAssetsIfNeeded(for: snapshot)"))
        XCTAssertTrue(chatViewsSource.contains(".task(id: selectedTab)"))
        XCTAssertTrue(chatViewsSource.contains("await state.prepareStickerExpressionPanel()"))
	    }

	    func testTranscriptTapDismissesExpressionPanel() throws {
	        let testFile = URL(fileURLWithPath: #filePath)
	        let chatViewsURL = testFile
	            .deletingLastPathComponent()
	            .deletingLastPathComponent()
	            .appendingPathComponent("BlueStoneIM/ChatViews.swift")
	        let source = try String(contentsOf: chatViewsURL, encoding: .utf8)

	        XCTAssertTrue(source.contains("dismissExpressionPanelFromTranscriptTap()"))
	        XCTAssertTrue(source.contains("private func dismissExpressionPanelFromTranscriptTap()"))
	        XCTAssertTrue(source.contains("guard showEmoji else { return }"))
	        XCTAssertTrue(source.contains("showEmoji = false"))
	    }

	    func testIOSComposerEmojiCatalogKeepsWebFallbackCoverage() throws {
	        let testFile = URL(fileURLWithPath: #filePath)
	        let chatViewsURL = testFile
	            .deletingLastPathComponent()
	            .deletingLastPathComponent()
	            .appendingPathComponent("BlueStoneIM/ChatViews.swift")
	        let source = try String(contentsOf: chatViewsURL, encoding: .utf8)
	        let requiredFallbackEmojis = [
	            "👎", "🤣", "😃", "😁", "😆", "😅", "😉", "🤩",
	            "🥳", "😢", "😡", "😱", "👋", "✌️", "🤞", "🤙",
	            "👈", "👉", "☝️", "✊", "🤝", "🧡", "💛", "💚",
	            "💙", "💜", "🖤", "🤍", "💔", "❤️‍🔥", "💕", "💯",
	            "💬", "📎", "📝", "📅", "⏰", "🔒", "🔔", "📣",
	            "📈", "⚠️", "❗", "❓", "🔍"
	        ]

	        for emoji in requiredFallbackEmojis {
	            XCTAssertTrue(source.contains("\"\(emoji)\""), "Missing composer emoji fallback: \(emoji)")
	        }
	    }

    func testEmojiCatalogRuntimeBacksOffRepeatedPanelReopensUntilRetryBoundary() throws {
        let scope = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "user-a"
        )
        let baseURL = try XCTUnwrap(URL(string: "https://example.test"))
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var runtime = EmojiPickerCatalogRuntimeState()

        XCTAssertEqual(
            runtime.begin(scope: scope, baseURL: baseURL, now: startedAt),
            .attempt
        )
        XCTAssertTrue(runtime.recordFailure(scope: scope, baseURL: baseURL, now: startedAt))
        XCTAssertEqual(
            runtime.begin(scope: scope, baseURL: baseURL, now: startedAt.addingTimeInterval(1)),
            .useFallback
        )
        XCTAssertEqual(
            runtime.begin(
                scope: scope,
                baseURL: baseURL,
                now: startedAt.addingTimeInterval(EmojiPickerCatalogRuntimeState.initialRetryDelay)
            ),
            .attempt
        )
        runtime.cancelAttempt(scope: scope, baseURL: baseURL)
        XCTAssertEqual(
            runtime.begin(
                scope: scope,
                baseURL: baseURL,
                now: startedAt.addingTimeInterval(EmojiPickerCatalogRuntimeState.initialRetryDelay)
            ),
            .attempt
        )
    }

    func testEmojiCatalogRuntimeReusesSuccessOnlyForMatchingIdentityAndRoute() throws {
        let scopeA = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "user-a"
        )
        let scopeB = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-b",
            tenantID: "tenant-a",
            imUID: "user-b"
        )
        let baseA = try XCTUnwrap(URL(string: "https://example.test"))
        let baseB = try XCTUnwrap(URL(string: "https://backup.example.test"))
        let now = Date(timeIntervalSince1970: 2_000)
        let catalog = EmojiCatalog(
            schema: emojiCatalogProjectionSchema,
            catalogSchema: unicodeEmojiCatalogSchema,
            catalogVersion: frozenEmojiCatalogVersion,
            catalogHash: frozenEmojiCatalogHash,
            emojiVersion: "17.0",
            cldrVersion: "48",
            items: []
        )
        var runtime = EmojiPickerCatalogRuntimeState()

        XCTAssertEqual(runtime.begin(scope: scopeA, baseURL: baseA, now: now), .attempt)
        XCTAssertTrue(runtime.recordSuccess(catalog, scope: scopeA, baseURL: baseA))
        XCTAssertEqual(runtime.begin(scope: scopeA, baseURL: baseA, now: now), .useCatalog(catalog))
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseA, now: now), .attempt)

        XCTAssertTrue(runtime.recordFailure(scope: scopeB, baseURL: baseA, now: now))
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseA, now: now), .useFallback)
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseB, now: now), .attempt)
    }

    func testIOSComposerWiresCatalogBackoffWithoutMergingStickerPackRefresh() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let chatViewsURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BlueStoneIM/ChatViews.swift")
        let source = try String(contentsOf: chatViewsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("state.emojiPickerCatalogRuntime.begin("))
        XCTAssertTrue(source.contains("state.emojiPickerCatalogRuntime.recordSuccess("))
        XCTAssertTrue(source.contains("state.emojiPickerCatalogRuntime.recordFailure("))
        XCTAssertTrue(source.contains("case .useFallback:"))
        XCTAssertTrue(source.contains("表情目录暂不可用，已使用本地 Emoji"))
        XCTAssertFalse(source.contains("表情目录加载失败，可重试"))
        XCTAssertTrue(source.contains("case .stickers: return \"表情包\""))
        XCTAssertTrue(source.contains("state.refreshStickerExpressionPanel()"))
    }

	    func testCachedRemoteSnapshotRoundTrip() throws {
	        let snapshot = CachedRemoteSnapshot(
            schemaVersion: 1,
            scope: "account|tenant",
            createdAt: 1_777_000_000,
            conversations: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CachedRemoteSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(decoded.scope, snapshot.scope)
        XCTAssertEqual(decoded.createdAt, snapshot.createdAt)
        XCTAssertTrue(decoded.conversations.isEmpty)
    }

    func testCaptchaUserMessageMapsKnownCodesAndSanitizesBackendReason() {
        XCTAssertEqual(
            captchaUserMessage(code: "captcha_config_missing", reason: nil, fallback: "fallback"),
            "验证码配置缺失，请联系管理员"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "captcha_channel_unavailable", reason: "captcha resource is not ready", fallback: "fallback"),
            "当前验证码通道不可用"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "rate_limited", reason: "请 30 秒后再试", fallback: "fallback"),
            "请 30 秒后再试"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "rate_limit_unavailable", reason: "rate limit state is temporarily unavailable", fallback: "fallback"),
            "服务繁忙，请稍后重试"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "unknown", reason: "internal server error: token leak", fallback: "验证码服务暂不可用"),
            "验证码服务暂不可用"
        )
    }

    func testRTCCallPayloadDecodesDeviceFields() throws {
        let json = """
        {
          "call": {
            "call_id": "call-123",
            "status": "accepted",
            "room_id": "room-123",
            "rtc_token": "call-token",
            "call_type": "audio",
            "channel_type": "direct",
            "channel_id": "direct-a-b",
            "caller_uid": "uid-a",
            "callee_uid": "uid-b",
            "created_at": "2026-06-26T01:59:00Z",
            "started_at": "2026-06-26T02:00:10Z",
            "accepted_at": "2026-06-26T02:00:20Z",
            "ended_at": "2026-06-26T02:03:20Z",
            "updated_at": "2026-06-26T02:03:21Z",
            "caller_profile": {
              "uid": "uid-a",
              "display_name": "Alice",
              "avatar": "/avatars/alice.png",
              "avatar_version": "caller-v1",
              "avatar_updated_at": "2026-06-26T02:00:00Z"
            },
            "callee_avatar_url": "/avatars/bob.png",
            "callee_avatar_version": "callee-v2",
            "callee_avatar_updated_at": "2026-06-26T02:05:00Z",
            "caller_device": {
              "device_id": "web-123",
              "device_type": "web"
            },
            "callee_device": {
              "device_id": "ios-456",
              "device_type": "ios"
            },
            "accepted_device": {
              "uid": "uid-b",
              "device_id": "ios-456",
              "device_type": "ios"
            }
          },
          "rtc_token": "response-token"
        }
        """

        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.rtcToken, "response-token")
        XCTAssertEqual(response.call.id, "call-123")
        XCTAssertEqual(response.call.rtcToken, "call-token")
        XCTAssertEqual(response.call.callerProfile?.displayName, "Alice")
        XCTAssertEqual(response.call.callerAvatarURL, "/avatars/alice.png")
        XCTAssertEqual(response.call.callerAvatarVersion, "caller-v1")
        XCTAssertEqual(response.call.callerAvatarUpdatedAt, "2026-06-26T02:00:00Z")
        XCTAssertEqual(response.call.calleeAvatarURL, "/avatars/bob.png")
        XCTAssertEqual(response.call.calleeAvatarVersion, "callee-v2")
        XCTAssertEqual(response.call.calleeAvatarUpdatedAt, "2026-06-26T02:05:00Z")
        XCTAssertEqual(response.call.callerDevice?.deviceID, "web-123")
        XCTAssertEqual(response.call.calleeDevice?.deviceType, "ios")
        XCTAssertEqual(response.call.acceptedDevice?.uid, "uid-b")
        XCTAssertEqual(response.call.acceptedDevice?.deviceID, "ios-456")
        XCTAssertEqual(response.call.createdAt, "2026-06-26T01:59:00Z")
        XCTAssertEqual(response.call.startedAt, "2026-06-26T02:00:10Z")
        XCTAssertEqual(response.call.acceptedAt, "2026-06-26T02:00:20Z")
        XCTAssertEqual(response.call.endedAt, "2026-06-26T02:03:20Z")
        XCTAssertEqual(response.call.updatedAt, "2026-06-26T02:03:21Z")
    }

    func testRTCVideoProviderFailsClosedAndDecodesFrozenCapabilitiesContract() throws {
        let legacy = try JSONDecoder().decode(RemoteRTCProvider.self, from: Data("""
        {
          "call_types": ["audio", "video"],
          "video_supported": true,
          "media_plane_configured": true,
          "ice_servers_configured": true
        }
        """.utf8))
        XCTAssertFalse(legacy.supportsVideo)

        let current = try JSONDecoder().decode(RemoteRTCProvider.self, from: Data("""
        {
          "call_types": ["audio", "video"],
          "video_supported": true,
          "voice_call_enabled": true,
          "video_call_enabled": true,
          "capabilities_version": "video-call-v1",
          "media_plane_configured": true,
          "ice_servers_configured": true
        }
        """.utf8))
        XCTAssertTrue(current.supportsAudio)
        XCTAssertTrue(current.supportsVideo)
        XCTAssertEqual(current.capabilitiesVersion, RTCDeviceCapabilities.protocolVersion)
    }

    func testRTCVideoCallDecodesMediaModesAndPeerCapability() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-video-1",
            "status": "accepted",
            "call_type": "video",
            "requested_media_mode": "video",
            "media_mode": "audio",
            "peer_capability_status": "supported",
            "caller_capabilities": {
              "version": "video-call-v1",
              "audio": true,
              "video": true,
              "camera_available": false
            }
          },
          "rtc_token": "short-lived-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.callType, "video")
        XCTAssertEqual(response.call.requestedMediaMode, "video")
        XCTAssertEqual(response.call.mediaMode, "audio")
        XCTAssertEqual(response.call.peerCapabilityStatus, "supported")
        XCTAssertEqual(response.call.callerCapabilities?.cameraAvailable, false)
    }

    func testRTCVoiceCreateResponseDecodesOmittedCapabilityVersionInsteadOfSurfacingHTTP201Phrase() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-audio-201",
            "status": "ringing",
            "call_type": "audio",
            "caller_capabilities": {
              "audio": false,
              "video": false,
              "camera_available": false
            }
          },
          "rtc_token": "voice-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.id, "call-audio-201")
        XCTAssertEqual(response.call.status, "ringing")
        XCTAssertEqual(response.call.callerCapabilities?.version, "")
        XCTAssertEqual(response.call.callerCapabilities?.audio, false)
        XCTAssertEqual(response.rtcToken, "voice-token")
    }

    func testRTCVideoCreateResponseDecodesOmittedCapabilityFieldsAsSafeFalseDefaults() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-video-201",
            "status": "ringing",
            "call_type": "video",
            "requested_media_mode": "video",
            "caller_capabilities": {}
          },
          "rtc_token": "video-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.id, "call-video-201")
        XCTAssertEqual(response.call.status, "ringing")
        XCTAssertEqual(response.call.requestedMediaMode, "video")
        XCTAssertEqual(response.call.callerCapabilities?.version, "")
        XCTAssertEqual(response.call.callerCapabilities?.audio, false)
        XCTAssertEqual(response.call.callerCapabilities?.video, false)
        XCTAssertEqual(response.call.callerCapabilities?.cameraAvailable, false)
        XCTAssertEqual(response.rtcToken, "video-token")
    }

    func testRTCIceCredentialContractsDecodeServerScheduleAndReboundToken() throws {
        let join = try JSONDecoder().decode(
            RemoteRTCRoomJoinData.self,
            from: Data(
                """
                {
                  "room_id": "room-1",
                  "media": {
                    "ice_servers": [{"urls": ["turn:relay.example.test"]}],
                    "ice_credential_expires_at": "2026-07-25T12:20:00Z",
                    "ice_credential_refresh_after": "2026-07-25T12:08:00Z"
                  }
                }
                """.utf8
            )
        )
        XCTAssertEqual(join.media.iceCredentialExpiresAt, "2026-07-25T12:20:00Z")
        XCTAssertEqual(join.media.iceCredentialRefreshAfter, "2026-07-25T12:08:00Z")

        let refresh = try JSONDecoder().decode(
            RemoteRTCIceCredentials.self,
            from: Data(
                """
                {
                  "ice_servers": [{"urls": ["turn:relay-2.example.test"]}],
                  "rtc_token": "rebound-token",
                  "ice_credential_expires_at": "2026-07-25T12:40:00Z",
                  "ice_credential_refresh_after": "2026-07-25T12:28:00Z"
                }
                """.utf8
            )
        )
        XCTAssertEqual(refresh.rtcToken, "rebound-token")
        XCTAssertEqual(refresh.iceCredentialExpiresAt, "2026-07-25T12:40:00Z")
        XCTAssertEqual(refresh.iceCredentialRefreshAfter, "2026-07-25T12:28:00Z")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteRTCIceCredentials.self,
                from: Data(#"{"ice_servers":[]}"#.utf8)
            )
        )
    }

    func testRTCVoiceIceMatrixAcceptsBothOrEitherTurnNodeAndRejectsZeroTurnNodes() throws {
        func decode(_ json: String) throws -> [RemoteRTCIceServer] {
            try JSONDecoder().decode([RemoteRTCIceServer].self, from: Data(json.utf8))
        }

        let both = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turn:turn-a.example.test:3478","turns:turn-a.example.test:5349"],"username":"a","credential":"secret-a"},{"urls":["turn:turn-b.example.test:3478","turns:turn-b.example.test:5349"],"username":"b","credential":"secret-b"}]"#
        )
        let onlyA = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turn:turn-a.example.test:3478"],"username":"a","credential":"secret-a"}]"#
        )
        let onlyB = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turns:turn-b.example.test:5349"],"username":"b","credential":"secret-b"}]"#
        )
        let zero = try decode(#"[{"urls":["stun:stun.example.test"]}]"#)

        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(both), 2)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(onlyA), 1)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(onlyB), 1)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(zero), 0)
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(both))
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(onlyA))
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(onlyB))
        XCTAssertFalse(RTCVoiceIceServerSet.hasUsableTurnRelay(zero))
    }

    func testRTCVoiceRecoveryBudgetIsTwoRoundsWithinFifteenSeconds() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var budget = RTCVoiceRecoveryBudget()

        budget.startWindowIfNeeded(now: startedAt)
        XCTAssertEqual(budget.claimAttempt(now: startedAt), 1)
        XCTAssertEqual(budget.claimAttempt(now: startedAt.addingTimeInterval(6)), 2)
        XCTAssertNil(budget.claimAttempt(now: startedAt.addingTimeInterval(7)))
        XCTAssertEqual(budget.remainingWindow(now: startedAt.addingTimeInterval(15)), 0)

        var expiredBudget = RTCVoiceRecoveryBudget()
        XCTAssertEqual(expiredBudget.claimAttempt(now: startedAt), 1)
        XCTAssertNil(expiredBudget.claimAttempt(now: startedAt.addingTimeInterval(15)))
        expiredBudget.reset()
        XCTAssertEqual(expiredBudget.claimAttempt(now: startedAt.addingTimeInterval(60)), 1)
        XCTAssertEqual(expiredBudget.attempts, 1)
    }

    @MainActor
    func testRTCVoiceRecoveryDeadlineTerminatesHungAsyncOperation() async {
        let startedAt = Date()
        var hungOperationCancelled = false

        do {
            try await RTCVoiceRecoveryDeadline.run(timeout: 0.02) {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    hungOperationCancelled = true
                    throw CancellationError()
                }
            }
            XCTFail("Expected the recovery deadline to terminate the hung operation")
        } catch {
            XCTAssertEqual(error as? RTCVoiceRecoveryDeadlineError, .exceeded)
        }
        for _ in 0..<20 where !hungOperationCancelled {
            await Task.yield()
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertTrue(hungOperationCancelled)
    }

    func testRTCVoiceRefreshSnapshotRejectsLateSessionAndTokenResults() {
        let snapshot = RTCVoiceCredentialRefreshSnapshot(
            sessionEpoch: 3,
            recoveryGeneration: 7,
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "token-generation-1"
        )

        XCTAssertTrue(
            snapshot.matches(
                sessionEpoch: 3,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-1"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 4,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-1"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 3,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-2"
            )
        )
    }

    func testRTCVoIPPushPayloadParsesRingingContractAndStableUUID() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "ringing",
            "call_id": "call-voice-1",
            "room_id": "room-voice-1",
            "tenant_id": "tenant-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "/avatars/mengyao.png",
            "caller_avatar_version": "voice-v1",
            "caller_avatar_updated_at": "2026-06-26T03:00:00Z",
            "call_type": "audio",
            "provider": "self_hosted_webrtc",
            "issued_at": "2026-06-26T01:02:03Z",
            "expires_at": "2026-06-26T01:03:03Z"
        ]))

        XCTAssertTrue(payload.isRinging)
        XCTAssertFalse(payload.isTerminal)
        XCTAssertEqual(payload.kind, "rtc_call")
        XCTAssertEqual(payload.callID, "call-voice-1")
        XCTAssertEqual(payload.roomID, "room-voice-1")
        XCTAssertEqual(payload.callerUID, "WXT00000003")
        XCTAssertEqual(payload.calleeUID, "WXT00000002")
        XCTAssertEqual(payload.callerName, "孟瑶")
        XCTAssertEqual(payload.callerAvatarURL, "/avatars/mengyao.png")
        XCTAssertEqual(payload.callerAvatarVersion, "voice-v1")
        XCTAssertEqual(payload.callerAvatarUpdatedAt, "2026-06-26T03:00:00Z")
        XCTAssertEqual(payload.callType, "audio")
        XCTAssertEqual(payload.provider, "self_hosted_webrtc")
        XCTAssertTrue(payload.isPushKitEligibleRinging)
        XCTAssertEqual(
            payload.deliveryFreshness(now: ISO8601DateFormatter().date(from: "2026-06-26T01:02:30Z")!),
            .fresh
        )
        XCTAssertEqual(
            payload.deliveryFreshness(now: ISO8601DateFormatter().date(from: "2026-06-26T01:03:04Z")!),
            .expired
        )
        XCTAssertEqual(payload.deterministicUUID, RTCVoIPPushPayload.deterministicUUIDForCallKit("call-voice-1"))
    }

    func testRTCVoIPPushPayloadParsesAPNsNestedRTCCallPayload() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "aps": [
                "alert": [
                    "title": "语音来电",
                    "body": "来自孟瑶"
                ],
                "sound": "default"
            ],
            "rtc_call": [
                "type": "rtc_call",
                "event": "ringing",
                "call_id": "call-voice-nested",
                "room_id": "room-voice-nested",
                "tenant_id": "tenant-1",
                "caller_uid": "WXT00000003",
                "callee_uid": "WXT00000002",
                "caller_name": "孟瑶",
                "caller_profile": [
                    "uid": "WXT00000003",
                    "nickname": "孟瑶",
                    "avatar_url": "/avatars/mengyao-profile.png",
                    "avatar_version": "voice-v2",
                    "avatar_updated_at": "2026-06-26T03:05:00Z"
                ] as [String: Any],
                "call_type": "audio",
                "provider": "self_hosted_webrtc"
            ]
        ]))

        XCTAssertTrue(payload.isRinging)
        XCTAssertEqual(payload.callID, "call-voice-nested")
        XCTAssertEqual(payload.roomID, "room-voice-nested")
        XCTAssertEqual(payload.callerName, "孟瑶")
        XCTAssertEqual(payload.callerProfile?.uid, "WXT00000003")
        XCTAssertEqual(payload.callerAvatarURL, "/avatars/mengyao-profile.png")
        XCTAssertEqual(payload.callerAvatarVersion, "voice-v2")
        XCTAssertEqual(payload.callerAvatarUpdatedAt, "2026-06-26T03:05:00Z")
        XCTAssertEqual(payload.provider, "self_hosted_webrtc")
    }

    func testRTCVoIPPushPayloadMapsTerminalCancelAndRejectsNonRTC() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "cancel",
            "call_id": "call-voice-2"
        ]))

        XCTAssertTrue(payload.isTerminal)
        XCTAssertFalse(payload.isPushKitEligibleRinging)
        XCTAssertEqual(payload.normalizedTerminalEvent, "canceled")
        XCTAssertNil(RTCVoIPPushPayload(dictionary: [
            "kind": "message",
            "event": "ringing",
            "call_id": "call-voice-2"
        ]))
    }

    func testRemotePushTokenRegistrationFingerprintIsStableSHA256AndNeverRawToken() {
        let registration = RemoteDeviceRegistration.apns(
            token: "secret",
            bundleID: "app.mltest.com",
            environment: "production"
        )

        XCTAssertEqual(
            registration.tokenFingerprint,
            "2bb80d537b1da3e38bd30361aa855686bde0ba6fdd2b0f0a9e3b8cbeeef7b1a"
        )
        XCTAssertNotEqual(registration.tokenFingerprint, registration.pushToken)
    }

    func testRemotePushTokenRetirementResponseRejectsUnknownOrMismatchedContractValues() throws {
        let decoder = JSONDecoder()
        let valid = try decoder.decode(
            RemotePushTokenRetirementResponse.self,
            from: Data(#"{"status":"already_empty","slot":"ordinary","provider":"apns","terminal":true}"#.utf8)
        )
        XCTAssertEqual(valid.status, .alreadyEmpty)
        XCTAssertEqual(valid.slot, .ordinary)
        XCTAssertEqual(valid.provider, .apns)
        XCTAssertTrue(valid.terminal)

        for invalid in [
            #"{"status":"unknown","slot":"ordinary","provider":"apns","terminal":false}"#,
            #"{"status":"retired","slot":"voip","provider":"apns","terminal":false}"#,
            #"{"status":"retired","slot":"ordinary","provider":"apns_voip","terminal":false}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(RemotePushTokenRetirementResponse.self, from: Data(invalid.utf8)))
        }
    }

    func testRemoteNotificationTargetResolutionStrictlyDecodesFrozenAllowlistedShapes() throws {
        let decoder = JSONDecoder()
        let conversation = try decoder.decode(
            RemoteNotificationTargetResolution.self,
            from: Data(#"{"kind":"conversation","conversation_id":"conversation-opaque","message_id":"message-opaque","channel_seq":123}"#.utf8)
        )
        XCTAssertEqual(conversation.kind, .conversation)
        XCTAssertEqual(conversation.conversationID, "conversation-opaque")
        XCTAssertNil(conversation.systemDestination)

        let system = try decoder.decode(
            RemoteNotificationTargetResolution.self,
            from: Data(#"{"kind":"system","system_destination":"system_notification"}"#.utf8)
        )
        XCTAssertEqual(system.kind, .system)
        XCTAssertEqual(system.systemDestination, "system_notification")
        XCTAssertNil(system.conversationID)

        for invalid in [
            #"{"kind":"conversation","conversation_id":""}"#,
            #"{"kind":"conversation","conversation_id":"c","system_destination":"system_notification"}"#,
            #"{"kind":"system","system_destination":"other"}"#,
            #"{"kind":"system","system_destination":"system_notification","conversation_id":"c"}"#,
            #"{"kind":"conversation","conversation_id":"c","channel_seq":0}"#,
            #"{"kind":"conversation","conversation_id":"c","message_id":null}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(RemoteNotificationTargetResolution.self, from: Data(invalid.utf8)))
        }
    }

    func testRTCRoomJoinPayloadDecodesParticipants() throws {
        let json = """
        {
          "room_id": "room-123",
          "rtc_token": "rtc-token",
          "media": {
            "owt_base_url": "https://rtc.example.test",
            "ice_servers": [
              {
                "urls": ["turn:turn.example.test"],
                "username": "turn-user",
                "credential": "turn-pass"
              }
            ]
          },
          "self_participant": {
            "uid": "uid-a",
            "device_id": "ios-123",
            "device_type": "ios",
            "role": "caller",
            "joined_at": "2026-06-26T00:00:00Z"
          },
          "peer_participant": {
            "uid": "uid-b",
            "device_id": "web-456",
            "device_type": "web",
            "role": "callee",
            "joined_at": "2026-06-26T00:00:01Z"
          },
          "participants": [
            {
              "uid": "uid-a",
              "device_id": "ios-123",
              "device_type": "ios",
              "role": "caller",
              "joined_at": "2026-06-26T00:00:00Z"
            }
          ]
        }
        """

        let join = try JSONDecoder().decode(RemoteRTCRoomJoinData.self, from: Data(json.utf8))

        XCTAssertEqual(join.roomID, "room-123")
        XCTAssertEqual(join.rtcToken, "rtc-token")
        XCTAssertEqual(join.selfParticipant?.deviceID, "ios-123")
        XCTAssertEqual(join.peerParticipant?.uid, "uid-b")
        XCTAssertEqual(join.participants.first?.role, "caller")
        XCTAssertEqual(join.media.iceServers.first?.username, "turn-user")
    }

    func testRTCRoomJoinPayloadDecodesLegacyParticipantAsSelf() throws {
        let json = """
        {
          "participant": {
            "tenant_id": "tenant-1",
            "room_id": "room-legacy",
            "im_uid": "uid-a",
            "device_id": "ios-123",
            "app_id": "com.jianhuitongim.app",
            "status": "joined",
            "joined_at": "2026-06-26T00:00:00Z"
          },
          "media": {
            "room_id": "room-legacy",
            "ice_servers": [
              { "urls": "stun:stun.example.test" }
            ]
          }
        }
        """

        let join = try JSONDecoder().decode(RemoteRTCRoomJoinData.self, from: Data(json.utf8))

        XCTAssertEqual(join.roomID, "room-legacy")
        XCTAssertEqual(join.selfParticipant?.uid, "uid-a")
        XCTAssertEqual(join.selfParticipant?.deviceID, "ios-123")
        XCTAssertEqual(join.selfParticipant?.role, "joined")
        XCTAssertEqual(join.participants.first?.deviceID, "ios-123")
        XCTAssertEqual(join.media.iceServers.first?.urls, ["stun:stun.example.test"])
    }

    func testRTCSignalEnvelopeDecodesItemsAndOfferData() throws {
        let json = """
        {
          "items": [
            {
              "from_uid": "uid-a",
              "from_device": "web-123",
              "to_uid": "uid-b",
              "to_device": "ios-456",
              "kind": "offer",
              "data": {
                "type": "offer",
                "sdp": "v=0\\r\\no=- 1 2 IN IP4 127.0.0.1"
              },
              "created_at": "2026-06-26T00:00:00Z"
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(RemoteRTCSignalItemsData.self, from: Data(json.utf8))
        let item = try XCTUnwrap(result.items.first)
        let offerData = try JSONEncoder().encode(item.data)
        let offer = try JSONDecoder().decode(RemoteRTCSessionDescriptionSignalData.self, from: offerData)

        XCTAssertEqual(item.fromUID, "uid-a")
        XCTAssertEqual(item.fromDevice, "web-123")
        XCTAssertEqual(item.toUID, "uid-b")
        XCTAssertEqual(item.toDevice, "ios-456")
        XCTAssertEqual(item.kind, .offer)
        XCTAssertEqual(item.createdAt, "2026-06-26T00:00:00Z")
        XCTAssertEqual(offer.type, "offer")
        XCTAssertTrue(offer.isOfferOrAnswer)
        XCTAssertEqual(offer.sdp, "v=0\r\no=- 1 2 IN IP4 127.0.0.1")
    }

    func testRTCSignalEnvelopeEncodesSendBody() throws {
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "uid-b",
            toDevice: "ios-456",
            kind: .answer,
            data: [
                "type": .string("answer"),
                "sdp": .string("v=0...")
            ]
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["to_uid"] as? String, "uid-b")
        XCTAssertEqual(object?["to_device"] as? String, "ios-456")
        XCTAssertEqual(object?["kind"] as? String, "answer")
        let payload = try XCTUnwrap(object?["data"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "answer")
        XCTAssertEqual(payload["sdp"] as? String, "v=0...")
    }

    func testRTCSignalV2DecodesCursorEnvelopeAndDeduplicationResult() throws {
        let page = try JSONDecoder().decode(RemoteRTCSignalItemsData.self, from: Data("""
        {
          "items": [{
            "server_cursor": "cursor-9",
            "message_id": "message-9",
            "seq": 9,
            "negotiation_id": "neg-1",
            "call_id": "call-video-1",
            "from_uid": "uid-a",
            "from_device": "ios-a",
            "to_uid": "uid-b",
            "to_device": "ios-b",
            "kind": "ice_restart",
            "data": {"reason": "network_changed"},
            "created_at": "2026-07-25T00:00:00Z"
          }],
          "next_cursor": "cursor-9",
          "has_more": false
        }
        """.utf8))
        XCTAssertEqual(page.nextCursor, "cursor-9")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.items.first?.messageID, "message-9")
        XCTAssertEqual(page.items.first?.kind, .iceRestart)

        let result = try JSONDecoder().decode(RemoteRTCSignalPostResult.self, from: Data("""
        {
          "message_id": "message-9",
          "server_cursor": "cursor-9",
          "duplicate": true,
          "server_received_at": "2026-07-25T00:00:00Z",
          "expires_at": "2026-07-25T00:05:00Z"
        }
        """.utf8))
        XCTAssertTrue(result.duplicate)
        XCTAssertEqual(result.serverCursor, "cursor-9")
    }

    func testRTCSignalV2EnvelopeCarriesStableIdentityAndNeverNeedsCredentials() throws {
        let envelope = RemoteRTCSignalEnvelope(
            protocolVersion: RTCDeviceCapabilities.protocolVersion,
            messageID: "message-1",
            seq: 1,
            negotiationID: "neg-1",
            callID: "call-video-1",
            toUID: "uid-b",
            toDevice: "ios-b",
            kind: .mediaState,
            data: ["camera_enabled": .bool(false)],
            sentAt: "2026-07-25T00:00:00Z"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        XCTAssertEqual(object["protocol_version"] as? String, "video-call-v1")
        XCTAssertEqual(object["message_id"] as? String, "message-1")
        XCTAssertEqual(object["seq"] as? Int, 1)
        XCTAssertNil(object["rtc_token"])
        XCTAssertNil(object["credential"])
    }

    func testRTCCandidateDataDecodesSingleAndBatchFormats() throws {
        let snakeCaseSingle = try JSONDecoder().decode(RemoteRTCIceCandidatesSignalData.self, from: Data("""
        {
          "candidate": "candidate:single",
          "sdp_mid": "0",
          "sdp_mline_index": 0,
          "username_fragment": "ufrag-single"
        }
        """.utf8))

        let camelCaseBatch = try JSONDecoder().decode(RemoteRTCIceCandidatesSignalData.self, from: Data("""
        {
          "candidates": [
            {
              "candidate": "candidate:first",
              "sdpMid": "0",
              "sdpMLineIndex": 0,
              "usernameFragment": "ufrag-first"
            },
            {
              "candidate": "candidate:second",
              "sdpMid": null,
              "sdpMLineIndex": null
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(snakeCaseSingle.candidates.count, 1)
        XCTAssertEqual(snakeCaseSingle.candidates.first?.candidate, "candidate:single")
        XCTAssertEqual(snakeCaseSingle.candidates.first?.sdpMid, "0")
        XCTAssertEqual(snakeCaseSingle.candidates.first?.sdpMLineIndex, 0)
        XCTAssertEqual(snakeCaseSingle.candidates.first?.usernameFragment, "ufrag-single")
        XCTAssertEqual(camelCaseBatch.candidates.map(\.candidate), ["candidate:first", "candidate:second"])
        XCTAssertEqual(camelCaseBatch.candidates.first?.sdpMid, "0")
        XCTAssertEqual(camelCaseBatch.candidates.first?.sdpMLineIndex, 0)
        XCTAssertEqual(camelCaseBatch.candidates.first?.usernameFragment, "ufrag-first")
        XCTAssertNil(camelCaseBatch.candidates[1].sdpMid)
        XCTAssertNil(camelCaseBatch.candidates[1].sdpMLineIndex)
    }

    func testRTCIceCandidateCodableWritesOnlyFrozenSnakeCaseKeys() throws {
        let candidate = RemoteRTCIceCandidateSignalData(
            candidate: "candidate:direct",
            sdpMid: "video",
            sdpMLineIndex: 1,
            usernameFragment: "ufrag-direct"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )

        XCTAssertEqual(object["candidate"] as? String, "candidate:direct")
        XCTAssertEqual(object["sdp_mid"] as? String, "video")
        XCTAssertEqual(object["sdp_mline_index"] as? Int, 1)
        XCTAssertEqual(object["username_fragment"] as? String, "ufrag-direct")
        XCTAssertNil(object["sdpMid"])
        XCTAssertNil(object["sdpMLineIndex"])
        XCTAssertNil(object["usernameFragment"])
    }

    func testRTCSignalPayloadCodecEncodesCandidateAsBatchForSend() throws {
        let data = RTCSignalPayloadCodec.candidateData([
            RemoteRTCIceCandidateSignalData(
                candidate: "candidate:local",
                sdpMid: "0",
                sdpMLineIndex: 0,
                usernameFragment: "ufrag-local"
            )
        ])
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "uid-b",
            toDevice: "ios-456",
            kind: .candidate,
            data: data
        )

        let encoded = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(object["data"] as? [String: Any])
        let candidates = try XCTUnwrap(payload["candidates"] as? [[String: Any]])

        XCTAssertNil(payload["candidate"])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?["candidate"] as? String, "candidate:local")
        XCTAssertEqual(candidates.first?["sdp_mid"] as? String, "0")
        XCTAssertEqual(candidates.first?["sdp_mline_index"] as? Int, 0)
        XCTAssertEqual(candidates.first?["username_fragment"] as? String, "ufrag-local")
        XCTAssertNil(candidates.first?["sdpMid"])
        XCTAssertNil(candidates.first?["sdpMLineIndex"])
        XCTAssertNil(candidates.first?["usernameFragment"])
    }

    func testRTCSignalPayloadCodecUsesStrictEOCAndRestartPayloads() {
        XCTAssertTrue(RTCSignalPayloadCodec.iceCompleteData.isEmpty)
        XCTAssertEqual(
            RTCSignalPayloadCodec.iceRestartData(),
            ["reason": .string("stable_token")]
        )
    }

    func testRTCVoiceMediaEventsKeepAcceptedAndJoinBeforeConnected() {
        XCTAssertEqual(RTCVoiceMediaEvent.callAccepted.mediaState, .preparing)
        XCTAssertEqual(RTCVoiceMediaEvent.roomJoined.mediaState, .preparing)
        XCTAssertEqual(RTCVoiceMediaEvent.remoteAudioTrackReady.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.localDescriptionSet.mediaState, .signaling)
        XCTAssertEqual(RTCVoiceMediaEvent.iceChecking.mediaState, .connecting)

        XCTAssertFalse(RTCVoiceMediaEvent.callAccepted.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.roomJoined.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.remoteAudioTrackReady.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.localDescriptionSet.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.iceChecking.qualifiesForConnectedAt)

        XCTAssertEqual(RTCVoiceMediaEvent.iceConnected.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.iceCompleted.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.peerConnectionConnected.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.connectionRecovered.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.remoteAudioRTPReady.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.recoveryExhausted.mediaState, .failed)
        XCTAssertFalse(RTCVoiceMediaEvent.iceConnected.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.iceCompleted.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.peerConnectionConnected.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.remoteAudioRTPReady.qualifiesForConnectedAt)
    }

    func testRemoteAppCurrentPolicyDecodesSnakeAndCamelAliases() throws {
        let snake = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jht-ios-main",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": false,
          "allow_default_tenant_join": true,
          "require_real_name": true,
          "require_phone_verification": false,
          "department_enabled": true,
          "support_contact_email": "support@example.com",
          "support_contact_configured": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let camel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "appId": "jht-ios-main",
          "platform": "ios",
          "status": "disabled",
          "allowWorkspaceSwitch": true,
          "allowDefaultTenantJoin": false,
          "requireRealName": false,
          "requirePhoneVerification": true,
          "organization": {
            "departmentEnabled": true
          },
          "supportContactEmail": "",
          "supportContactConfigured": false,
          "cacheTTLSeconds": 30
        }
        """.utf8))

        XCTAssertEqual(snake.appID, "jht-ios-main")
        XCTAssertEqual(snake.platform, "ios")
        XCTAssertFalse(snake.allowWorkspaceSwitch)
        XCTAssertTrue(snake.allowDefaultTenantJoin)
        XCTAssertTrue(snake.requireRealName)
        XCTAssertFalse(snake.requirePhoneVerification)
        XCTAssertTrue(snake.departmentEnabled)
        XCTAssertEqual(snake.supportContactEmail, "support@example.com")
        XCTAssertTrue(snake.supportContactConfigured)
        XCTAssertFalse(snake.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(snake.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(snake.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(snake.cacheTTLSeconds, 60)
        XCTAssertTrue(snake.isUsable)

        XCTAssertEqual(camel.appID, "jht-ios-main")
        XCTAssertEqual(camel.platform, "ios")
        XCTAssertTrue(camel.allowWorkspaceSwitch)
        XCTAssertFalse(camel.allowDefaultTenantJoin)
        XCTAssertFalse(camel.requireRealName)
        XCTAssertTrue(camel.requirePhoneVerification)
        XCTAssertTrue(camel.departmentEnabled)
        XCTAssertEqual(camel.supportContactEmail, "")
        XCTAssertFalse(camel.supportContactConfigured)
        XCTAssertFalse(camel.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(camel.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(camel.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(camel.cacheTTLSeconds, 30)
        XCTAssertFalse(camel.isUsable)
    }

    func testPhoneAuthPolicyDefaultsToEnabledAndDecodesExplicitDisable() throws {
        let missing = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "allow_workspace_switch":true,
          "allow_default_tenant_join":true
        }
        """#.utf8))
        let disabled = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "allow_workspace_switch":true,
          "allow_default_tenant_join":true,
          "phone_auth_enabled":false
        }
        """#.utf8))

        XCTAssertTrue(missing.phoneAuthEnabled)
        XCTAssertFalse(disabled.phoneAuthEnabled)
        XCTAssertTrue(disabled.settingPhoneAuthEnabled(true).phoneAuthEnabled)
    }

    func testRemoteAppCurrentPolicyDecodesRegistrationAndEnterpriseFirstAliasesAcrossSupportedNesting() throws {
        let snake = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "policy": {
            "allow_default_tenant_join": false,
            "auth_policy": { "prefer_enterprise_code": true },
            "register_policy": { "registration_enabled": false }
          },
          "preferred_enterprise_code":"wxt123456"
        }
        """#.utf8))
        let camel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "appId":"jht-ios-main",
          "status":"active",
          "appPolicy": {
            "allowDefaultTenantJoin": true,
            "loginPolicy": { "enterpriseCodeFirst": true },
            "registerPolicy": { "openRegistration": true }
          },
          "preferred_enterprise_code":"WXT654321"
        }
        """#.utf8))

        XCTAssertFalse(snake.allowDefaultTenantJoin)
        XCTAssertFalse(snake.registrationEnabled)
        XCTAssertTrue(snake.enterpriseCodeFirst)
        XCTAssertEqual(snake.preferredEnterpriseCode, "WXT123456")
        XCTAssertTrue(camel.allowDefaultTenantJoin)
        XCTAssertTrue(camel.registrationEnabled)
        XCTAssertTrue(camel.enterpriseCodeFirst)
        XCTAssertEqual(camel.preferredEnterpriseCode, "WXT654321")
    }

    func testRemoteAppCurrentPolicyLegacyDefaultsRegistrationEnabledAndEnterpriseFirstDisabled() throws {
        let policy = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {"app_id":"jht-ios-main","status":"active"}
        """#.utf8))

        XCTAssertTrue(policy.allowDefaultTenantJoin)
        XCTAssertTrue(policy.registrationEnabled)
        XCTAssertFalse(policy.enterpriseCodeFirst)
        XCTAssertEqual(policy.preferredEnterpriseCode, "")
    }

    func testAppBootstrapDecodesNestedPolicyAliasesAndFailsClosedForInvalidConfiguredFlags() throws {
        let enabled = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "appPolicy": {
            "registerPolicy": { "registrationOpen": "enabled" },
            "authPolicy": { "preferEnterpriseCode": 1 }
          },
          "preferredEnterpriseCode":"WXT000321"
        }
        """#.utf8))
        let invalid = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "registration_enabled":"not-a-boolean",
          "enterprise_code_first":"not-a-boolean"
        }
        """#.utf8))

        XCTAssertTrue(enabled.registrationEnabled)
        XCTAssertTrue(enabled.enterpriseCodeFirst)
        XCTAssertEqual(enabled.preferredEnterpriseCode, "WXT000321")
        XCTAssertFalse(invalid.registrationEnabled)
        XCTAssertFalse(invalid.enterpriseCodeFirst)
    }

    func testPreferredEnterpriseCodeRequiresAuthoritativeCanonicalAppAndSupportedFormat() throws {
        func decode(appID: String, code: String, enabled: Bool = true) throws -> RemoteAppCurrentPolicy {
            try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
            {"app_id":"\#(appID)","status":"active","enterprise_code_first":\#(enabled),"preferred_enterprise_code":"\#(code)"}
            """#.utf8))
        }

        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "wxt000123").preferredEnterpriseCode, "WXT000123")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: " ab001234 ").preferredEnterpriseCode, "AB001234")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "AB-I00A001").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "other-ios", code: "WXT000123").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "WXT12345").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "WXT000123", enabled: false).preferredEnterpriseCode, "")
    }

    func testAppBootstrapPreservesPhoneAuthFlagFromAllFrozenLocations() throws {
        let missing = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active"
        }
        """#.utf8))
        let topLevel = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "phone_auth_enabled":false
        }
        """#.utf8))

        XCTAssertTrue(missing.phoneAuthEnabled)
        XCTAssertFalse(topLevel.phoneAuthEnabled)

        for containerKey in ["auth_policy", "register_policy", "login_policy", "tenant_pool"] {
            let json = """
            {
              "app_id":"jianhuitong-ios",
              "status":"active",
              "\(containerKey)":{"phone_auth_enabled":false}
            }
            """
            let nested = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(json.utf8))
            XCTAssertFalse(nested.phoneAuthEnabled, "expected \(containerKey) to preserve phone_auth_enabled")
        }
    }

    func testRemoteAppCurrentPolicyDecodesAccessDiagnosticsPolicyFlags() throws {
        let topLevel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "access_diagnostics_overlay_enabled": true,
          "access_diagnostics_copy_enabled": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let nested = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "debug_features": {
            "access_diagnostics_overlay_enabled": "true",
            "access_diagnostics_copy_enabled": 1
          },
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let missing = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let explicitlyDisabled = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "access_diagnostics_overlay_enabled": false,
          "cache_ttl_seconds": 60
        }
        """.utf8))

        XCTAssertTrue(topLevel.accessDiagnosticsOverlayEnabled)
        XCTAssertTrue(topLevel.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(topLevel.accessDiagnosticsOverlayConfiguration, .enabled)
        XCTAssertTrue(nested.accessDiagnosticsOverlayEnabled)
        XCTAssertTrue(nested.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(nested.accessDiagnosticsOverlayConfiguration, .enabled)
        XCTAssertFalse(missing.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(missing.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(missing.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(missing.accessDiagnosticsOverlayConfiguration.displayText, "配置未获取")
        XCTAssertFalse(explicitlyDisabled.accessDiagnosticsOverlayEnabled)
        XCTAssertEqual(explicitlyDisabled.accessDiagnosticsOverlayConfiguration, .disabled)
        XCTAssertEqual(explicitlyDisabled.accessDiagnosticsOverlayConfiguration.displayText, "已关闭")
    }

    func testRemoteOrganizationTreeAndMembersDecodeDepartmentFields() throws {
        let tree = try JSONDecoder().decode(RemoteOrganizationTree.self, from: Data("""
        {
          "department_enabled": true,
          "can_manage": true,
          "can_manage_department": true,
          "root": {
            "department_id": "company",
            "name": "公司",
            "is_virtual": true,
            "member_count": 2,
            "children": [
              {
                "department_id": "dep-risk",
                "parent_department_id": "company",
                "name": "风控部",
                "department_path_names": ["公司", "风控部"],
                "member_count": 3,
                "children": []
              }
            ]
          },
          "items": []
        }
        """.utf8))

        XCTAssertTrue(tree.departmentEnabled)
        XCTAssertTrue(tree.canManage)
        XCTAssertTrue(tree.canManageDepartment)
        XCTAssertEqual(tree.root?.departmentID, "company")
        XCTAssertEqual(tree.root?.name, "公司")
        XCTAssertEqual(tree.root?.isVirtual, true)
        XCTAssertEqual(tree.root?.children.first?.departmentID, "dep-risk")
        XCTAssertEqual(tree.root?.children.first?.departmentPathNames, ["公司", "风控部"])

        let members = try JSONDecoder().decode(RemoteOrganizationMemberList.self, from: Data("""
        {
          "department_enabled": true,
          "canManage": true,
          "canManageDepartment": true,
          "department_id": "dep-risk",
          "items": [
            {
              "im_uid": "im-1",
              "user_id": "u-1",
              "nickname": "Alice",
              "department_id": "dep-risk",
              "department_name": "风控部",
              "department_path_names": ["公司", "风控部"],
              "position_name": "审核员",
              "is_primary": "true",
              "sort_order": "7"
            }
          ]
        }
        """.utf8))

        let member = try XCTUnwrap(members.items.first)
        XCTAssertTrue(members.departmentEnabled)
        XCTAssertTrue(members.canManage)
        XCTAssertTrue(members.canManageDepartment)
        XCTAssertEqual(members.departmentID, "dep-risk")
        XCTAssertEqual(member.id, "im-1")
        XCTAssertEqual(member.departmentName, "风控部")
        XCTAssertEqual(member.departmentPathNames, ["公司", "风控部"])
        XCTAssertTrue(member.isPrimary)
        XCTAssertEqual(member.sortOrder, 7)
    }

    func testRemoteTenantContextDecodesDepartmentPolicyAndUserDepartment() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "im-1",
          "app_id": "jht-ios-main",
          "device_id": "ios-1",
          "tenant": {
            "tenant_id": "tenant-1",
            "tenant_code": "WXT000001",
            "name": "测试企业",
            "status": "active"
          },
          "tenant_policy": {
            "organization": {
              "department_enabled": true
            }
          },
          "user": {
            "im_uid": "im-1",
            "user_id": "u-1",
            "nickname": "Alice",
            "department_name": "风控部",
            "department_path_names": ["公司", "风控部"]
          }
        }
        """.utf8))

        XCTAssertEqual(context.departmentEnabled, true)
        XCTAssertEqual(context.user?.departmentName, "风控部")
        XCTAssertEqual(context.user?.departmentPathNames, ["公司", "风控部"])
        XCTAssertEqual(context.clientPolicy?.allowMemberGroupCreation, false)
        XCTAssertEqual(context.clientPolicy?.clientFriendRequests, false)
        XCTAssertEqual(context.clientPolicy?.showGroupMemberCount, false)
        XCTAssertEqual(context.clientPolicy?.showOnlineStatus, true)
        XCTAssertEqual(context.clientPolicy?.showLastLoginTime, false)
        XCTAssertEqual(context.clientPolicy?.loginRequireBoundDevice, false)
        XCTAssertEqual(context.clientPolicy?.messageExportEnabled, false)
    }

    func testRemoteMeProfileDecodesTenantLocalAuthorityWatermark() throws {
        let profile = try JSONDecoder().decode(RemoteMeProfile.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "user_id": "user-1",
          "username": "alice01",
          "nickname": "Alice",
          "avatar": "avatar.png",
          "user_revision": "12",
          "identity_generation": 34
        }
        """.utf8))

        XCTAssertEqual(profile.tenantID, "tenant-1")
        XCTAssertEqual(profile.imUID, "uid-1")
        XCTAssertEqual(profile.nickname, "Alice")
        XCTAssertEqual(profile.userRevision, 12)
        XCTAssertEqual(profile.identityGeneration, 34)
    }

    func testTenantContextUserDecodesSameProfileAuthorityWatermark() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "app_id": "jianhuitong-ios",
          "device_id": "device-1",
          "tenant": {"tenant_id":"tenant-1","tenant_code":"WXT000001","name":"测试企业","status":"active"},
          "user": {
            "tenant_id": "tenant-1",
            "im_uid": "uid-1",
            "user_id": "user-1",
            "username": "alice01",
            "nickname": "Alice",
            "avatar": "avatar.png",
            "user_revision": 12,
            "identity_generation": "34"
          }
        }
        """.utf8))

        let user = try XCTUnwrap(context.user)
        XCTAssertEqual(user.tenantID, "tenant-1")
        XCTAssertEqual(user.imUID, "uid-1")
        XCTAssertEqual(user.nickname, "Alice")
        XCTAssertEqual(user.userRevision, 12)
        XCTAssertEqual(user.identityGeneration, 34)
    }

    func testRemoteTenantContextDecodesGlobalPolicyNestedAndDefaults() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "im-1",
          "app_id": "jianhuitong-ios",
          "device_id": "ios-1",
          "tenant_policy": {
            "group": {
              "allow_member_group_creation": true,
              "hide_membership_system_messages": true
            },
            "relationship": {
              "client_friend_requests": true
            },
            "visibility": {
              "show_online_status": false,
              "show_last_login_time": true
            },
            "device": {
              "login_require_bound_device": true
            },
            "export": {
              "message_export_enabled": true
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertTrue(policy.allowMemberGroupCreation)
        XCTAssertTrue(policy.hideMembershipSystemMessages)
        XCTAssertTrue(policy.clientFriendRequests)
        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertFalse(policy.showOnlineStatus)
        XCTAssertTrue(policy.showLastLoginTime)
        XCTAssertTrue(policy.loginRequireBoundDevice)
        XCTAssertTrue(policy.messageExportEnabled)
    }

    func testRemoteTenantContextDecodesAuthoritativeMultiDevicePolicy() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "app_id": "jianhuitong-ios",
          "device_id": "device-1",
          "tenant": {"id":"tenant-1","tenantName":"Tenant"},
          "tenant_policy": {
            "device": {
              "multi_device_enabled": true,
              "authoritative": true,
              "contract_version": 1
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertTrue(policy.multiDevicePolicyPresent)
        XCTAssertTrue(policy.multiDevicePolicyAuthoritative)
        XCTAssertEqual(policy.multiDeviceContractVersion, 1)
        XCTAssertTrue(policy.multiDeviceEnabled)
    }

    func testRemoteTenantContextTreatsIncompleteOrMalformedMultiDevicePolicyAsUnresolved() throws {
        let malformedDevicePolicies = [
            #"{"multi_device_enabled":true,"contract_version":1}"#,
            #"{"multi_device_enabled":"true","authoritative":true,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":"true","contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":true,"contract_version":"1"}"#,
            #"{"multi_device_enabled":true,"authoritative":false,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":true,"contract_version":2}"#
        ]

        for devicePolicy in malformedDevicePolicies {
            let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
            {"device":\(devicePolicy)}
            """.utf8))
            XCTAssertFalse(policy.multiDevicePolicyPresent, "must not claim authority for \(devicePolicy)")
        }
    }

    func testRemoteTenantContextDecodesRestrictiveGroupMemberCountWatermark() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "tenant_policy": {
            "visibility": {
              "show_group_member_count": false,
              "tenant_policy_generation": 12,
              "contract_version": 1,
              "authoritative": false
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 12)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 1)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertTrue(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyAcceptsFutureCompatibleGroupMemberCountContractVersion() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "tenant_policy_generation": 13,
            "contract_version": 2,
            "authoritative": true
          }
        }
        """.utf8))

        XCTAssertTrue(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 13)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 2)
        XCTAssertTrue(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertTrue(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyMissingGroupMemberCountFieldsUsesHiddenUnresolvedDefaults() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data(#"{}"#.utf8))

        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyRejectsMalformedCanonicalGroupMemberCountTypes() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": "true",
            "tenant_policy_generation": "12",
            "contract_version": 1.5,
            "authoritative": 1
          }
        }
        """.utf8))

        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyPartialGroupMemberCountContractRemainsUnresolved() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "tenant_policy_generation": 3,
            "contract_version": 1
          }
        }
        """.utf8))

        XCTAssertTrue(policy.showGroupMemberCount)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyRejectsDeprecatedCandidateWatermarkKeys() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "group_member_count_policy_generation": 99,
            "group_member_count_contract_version": 1,
            "group_member_count_policy_authoritative": true
          }
        }
        """.utf8))

        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantContextDecodesOnlyInternalCompatAsInverse() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "tenantPolicy": {
            "group": {
              "onlyInternalCanCreateGroup": false
            }
          }
        }
        """.utf8))

        XCTAssertEqual(context.clientPolicy?.allowMemberGroupCreation, true)
    }

    func testRemotePresenceAndLastLoginFieldsDecodeWithoutInferringOffline() throws {
        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "im-1",
          "user_id": "u-1",
          "nickname": "Alice",
          "status": "hidden",
          "last_seen_at": "2026-07-23T01:02:03Z"
        }
        """.utf8))
        XCTAssertEqual(user.status, "hidden")
        XCTAssertEqual(user.lastSeenAt, "2026-07-23T01:02:03Z")

        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "owner_uid": "me",
          "friend_uid": "friend-1",
          "friend_nickname": "Bob",
          "friend_status": "unknown",
          "friend_last_seen_at": "今天 08:52"
        }
        """.utf8))
        XCTAssertEqual(relation.friendStatus, "unknown")
        XCTAssertFalse(relation.friendOnlineKnown)
        XCTAssertEqual(relation.friendLastSeenAt, "今天 08:52")
    }

    func testTenantLoginWorkspaceKeepsEnterableWhenSwitchDisabled() throws {
        let login = try JSONDecoder().decode(RemoteTenantLoginData.self, from: Data("""
        {
          "platform_token": "platform-token",
          "can_direct_enter": true,
          "requires_workspace_selection": false,
          "auto_entered_workspace_id": "tenant-1",
          "workspaces": [
            {
              "id": "tenant-1",
              "name": "Local Tenant",
              "tenant_code": "WXT000001",
              "status": "active",
              "member_status": "active",
              "enterable": true,
              "can_switch": false
            }
          ]
        }
        """.utf8))

        let workspace = try XCTUnwrap(login.workspaces.first)
        XCTAssertTrue(login.canDirectEnter)
        XCTAssertFalse(login.requiresWorkspaceSelection)
        XCTAssertEqual(login.autoEnteredWorkspaceID, "tenant-1")
        XCTAssertEqual(workspace.enterable, true)
        XCTAssertFalse(workspace.canSwitch)
    }

    func testTenantSearchResponseDecodesBucketsHighlightsAndJumpTarget() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "search_id": "search-1",
          "request_id": "req-1",
          "elapsed_ms": 8,
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:msg-1",
                  "type": "message",
                  "title": "张三",
                  "subtitle": "昨天 19:03",
                  "snippet": "这里有合同正文",
                  "highlight_ranges": [
                    {"field":"snippet","start":3,"length":2}
                  ],
                  "rank": 9.5,
                  "jump_target": {
                    "kind": "message",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 42,
                    "message_id": "msg-1"
                  },
                  "source": {"visibility":"remote"}
                }
              ],
              "count": 1,
              "has_more": false
            },
            "files": {
              "items": [
                {
                  "result_id": "file:file-1",
                  "type": "file",
                  "title": "合同.pdf",
                  "source": "tenant.files",
                  "highlight_ranges": [
                    {"field":"title","start":0,"length":2}
                  ],
                  "jumpTarget": {
                    "kind": "message_file",
                    "channelId": "group-1",
                    "channelType": "group",
                    "channelSeq": "43",
                    "messageId": "msg-2",
                    "fileId": "file-1"
                  }
                }
              ],
              "count": 1,
              "hasMore": true,
              "nextCursor": "cursor-file"
            }
          },
          "items": [],
          "compatibility": {},
          "analytics": {},
          "parsed_filters": [
            {"type":"sender","key":"from","operator":"from","value":"u_100","label":"来自 u_100","raw":"from:u_100"},
            {"type":"date","key":"before","operator":"before","value":"2026-06-27"}
          ],
          "conversation_search": {
            "hit_channel_seqs": [42, 43],
            "total": 2,
            "next_cursor": "cursor-next"
          },
          "conversation_date_anchor": {
            "date": "2026-06-27",
            "status": "nearest",
            "nearest_channel_seq": 43,
            "nearest_message_id": "msg-2",
            "direction": "after"
          }
        }
        """.utf8))

        XCTAssertEqual(response.query, "合同")
        XCTAssertEqual(response.scope, "conversation")
        XCTAssertEqual(response.searchID, "search-1")
        XCTAssertEqual(response.elapsedMS, 8)
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.id, "message:message:msg-1")
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.highlightRanges.first, RemoteTenantSearchHighlightRange(field: "snippet", start: 3, length: 2))
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.jumpTarget?.channelSeq, 42)
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.source["visibility"]?.stringValue, "remote")
        XCTAssertEqual(response.resultsByType["files"]?.hasMore, true)
        XCTAssertEqual(response.resultsByType["files"]?.nextCursor, "cursor-file")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.jumpTarget?.fileID, "file-1")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.sourceName, "tenant.files")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.source["name"]?.stringValue, "tenant.files")
        XCTAssertEqual(response.parsedFilters.map(\.displayTitle), ["来自 u_100", "before: 2026-06-27"])
        XCTAssertEqual(response.conversationSearch?.hitChannelSeqs, [42, 43])
        XCTAssertEqual(response.conversationSearch?.nextCursor, "cursor-next")
        XCTAssertEqual(response.conversationDateAnchor?.nearestChannelSeq, 43)
        XCTAssertEqual(response.conversationDateAnchor?.bestJumpTarget?.messageID, "msg-2")
    }

    func testTenantSearchResponseDecodesLegacyArrayBucketsAndPinyinHighlights() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "zss",
          "scope": "global",
          "types": ["contacts"],
          "limit": 10,
          "results_by_type": {
            "contacts": [
              {
                "result_id": "contact:u_1",
                "type": "contact",
                "title": "张三石",
                "subtitle": "拼音命中",
                "highlight_ranges": [
                  {"field":"title","start":0,"length":3}
                ],
                "source": {"name":"tenant.contacts"}
              }
            ]
          }
        }
        """.utf8))

        let contactBucket = try XCTUnwrap(response.resultsByType["contacts"])
        XCTAssertEqual(contactBucket.count, 1)
        XCTAssertFalse(contactBucket.hasMore)
        XCTAssertEqual(contactBucket.items.first?.highlightRanges.first, RemoteTenantSearchHighlightRange(field: "title", start: 0, length: 3))
        XCTAssertEqual(contactBucket.items.first?.sourceName, "tenant.contacts")
    }

    func testConversationSearchPaginationKeepsMessagesAndFilesCursorsSeparate() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:msg-1",
                  "type": "message",
                  "title": "消息命中",
                  "jump_target": {
                    "kind": "message",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 101,
                    "message_id": "msg-1"
                  }
                }
              ],
              "count": 1,
              "has_more": true,
              "next_cursor": "messages-next"
            },
            "files": {
              "items": [
                {
                  "result_id": "file:file-1",
                  "type": "file",
                  "title": "合同.pdf",
                  "jump_target": {
                    "kind": "message_file",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 205,
                    "message_id": "msg-file",
                    "file_id": "file-1"
                  }
                }
              ],
              "count": 5,
              "has_more": true,
              "next_cursor": "files-next"
            }
          },
          "conversation_search": {
            "hit_channel_seqs": [101],
            "total": 1,
            "next_cursor": "compat-message-next"
          }
        }
        """.utf8))

        let items = ["messages", "files"].flatMap { response.resultsByType[$0]?.items ?? [] }
        let pagination = TenantConversationSearchPaginationState(response: response, items: items)

        XCTAssertTrue(pagination.hasMore)
        XCTAssertEqual(pagination.typeCursors["messages"], "messages-next")
        XCTAssertEqual(pagination.typeCursors["files"], "files-next")
        XCTAssertNotEqual(pagination.typeCursors["files"], pagination.typeCursors["messages"])
        XCTAssertNil(pagination.genericCursor(for: ["messages", "files"]))
        XCTAssertEqual(pagination.hitChannelSeqs, [101, 205])
        XCTAssertEqual(pagination.total, 6)
    }

    func testConversationSearchPaginationUsesCompatibilityCursorOnlyForMessages() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "results_by_type": {
            "messages": {
              "items": [],
              "count": 0,
              "has_more": false
            },
            "files": {
              "items": [],
              "count": 3,
              "has_more": true,
              "next_cursor": "files-next"
            }
          },
          "conversation_search": {
            "hit_channel_seqs": [],
            "total": 0,
            "next_cursor": "compat-message-next"
          }
        }
        """.utf8))

        let pagination = TenantConversationSearchPaginationState(response: response, items: [])

        XCTAssertTrue(pagination.hasMore)
        XCTAssertEqual(pagination.typeCursors["messages"], "compat-message-next")
        XCTAssertEqual(pagination.typeCursors["files"], "files-next")
        XCTAssertNil(pagination.genericCursor(for: ["messages", "files"]))
        XCTAssertEqual(pagination.genericCursor(for: ["messages"]), "compat-message-next")
        XCTAssertEqual(pagination.total, 3)
    }

    func testTenantSearchMessageDisplayHidesDuplicateTitleSnippet() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-1",
          "type": "message",
          "title": " 普通消息测试 1782525965 ",
          "snippet": "普通消息测试   1782525965",
          "subtitle": "普通消息测试 1782525965",
          "highlight_ranges": [
            {"field":"snippet","start":0,"length":2}
          ],
          "source": "tenant.messages"
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试   1782525965")
        XCTAssertEqual(display.primaryField, "snippet")
        XCTAssertNil(display.secondaryText)
    }

    func testTenantSearchMessageDisplayKeepsDistinctSubtitle() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-2",
          "type": "message",
          "title": "普通消息测试 1782525965",
          "snippet": "普通消息测试 1782525965",
          "subtitle": "QA 容量临界群 · 昨天 19:03",
          "source": "tenant.messages"
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试 1782525965")
        XCTAssertEqual(display.primaryField, "snippet")
        XCTAssertEqual(display.secondaryText, "QA 容量临界群 · 昨天 19:03")
        XCTAssertEqual(display.secondaryField, "subtitle")
    }

    func testTenantSearchDisplayDoesNotCaseFilterBackendResults() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "hello",
          "scope": "global",
          "types": ["messages", "files"],
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:hello-1",
                  "type": "message",
                  "title": "Hello",
                  "snippet": "Hello from backend",
                  "source": "tenant.messages"
                }
              ]
            },
            "files": {
              "items": [
                {
                  "result_id": "file:report-1",
                  "type": "file",
                  "title": "Report-Q2.pdf",
                  "snippet": "REPORT",
                  "source": "tenant.files"
                }
              ]
            }
          },
          "parsed_filters": [
            {"type":"sender","key":"from","operator":"FROM","value":"Alice","raw":"FROM:Alice"}
          ]
        }
        """.utf8))

        let message = try XCTUnwrap(response.resultsByType["messages"]?.items.first)
        let file = try XCTUnwrap(response.resultsByType["files"]?.items.first)
        let filter = try XCTUnwrap(response.parsedFilters.first)

        XCTAssertFalse(message.isBlockedFromChatSearchDisplay)
        XCTAssertFalse(file.isBlockedFromChatSearchDisplay)
        XCTAssertEqual(message.displayModel.primaryText, "Hello from backend")
        XCTAssertEqual(file.displayModel.primaryText, "Report-Q2.pdf")
        XCTAssertEqual(filter.operatorName, "FROM")
        XCTAssertEqual(filter.displayTitle, "from: Alice")
    }

    func testTenantSearchResultGuardBlocksExplicitRiskAndSystemMarkersOnly() throws {
        let blocked = try decodeTenantSearchResult("""
        {
          "result_id": "message:risk-1",
          "type": "message",
          "title": "风控通知",
          "snippet": "系统通知",
          "source": {
            "risk_notice": true,
            "content_type": "system"
          }
        }
        """)
        let ordinary = try decodeTenantSearchResult("""
        {
          "result_id": "message:normal-1",
          "type": "message",
          "title": "风控侧也已收到敏感通知，普通用户好",
          "snippet": "风控侧也已收到敏感通知，普通用户好",
          "source": "tenant.messages"
        }
        """)

        XCTAssertTrue(blocked.isBlockedFromChatSearchDisplay)
        XCTAssertFalse(ordinary.isBlockedFromChatSearchDisplay)
    }

    func testTenantSearchMessageDisplayUsesFriendlySourceLine() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-3",
          "type": "message",
          "title": "普通消息测试",
          "snippet": "普通消息测试",
          "subtitle": "group #28",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-28",
            "channel_type": "group",
            "channel_seq": 28,
            "message_id": "msg-3"
          },
          "source": {
            "conversation_title": "风控复核群",
            "sender_name": "普通用户",
            "display_time": "09:06"
          }
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试")
        XCTAssertEqual(display.secondaryText, "风控复核群 · 普通用户 · 09:06")
    }

    func testTenantSearchMessageDisplayFallsBackWithoutRawChannelID() throws {
        let groupItem = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-group",
          "type": "message",
          "title": "群消息",
          "snippet": "群消息",
          "subtitle": "group #28",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-28",
            "channel_type": "group",
            "channel_seq": 28,
            "message_id": "msg-group"
          },
          "source": "group #28"
        }
        """)
        let directItem = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-direct",
          "type": "message",
          "title": "单聊消息",
          "snippet": "单聊消息",
          "subtitle": "direct #2",
          "jump_target": {
            "kind": "message",
            "channel_id": "direct-2",
            "channel_type": "direct",
            "channel_seq": 2,
            "message_id": "msg-direct"
          },
          "source": "direct #2"
        }
        """)

        XCTAssertEqual(groupItem.displayModel.secondaryText, "群聊")
        XCTAssertEqual(directItem.displayModel.secondaryText, "单聊")
        XCTAssertFalse(groupItem.displayModel.secondaryText?.contains("#") == true)
        XCTAssertFalse(directItem.displayModel.secondaryText?.contains("#") == true)
    }

    func testTenantSearchFileDisplayUsesFriendlySourceLine() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "file:file-1",
          "type": "file",
          "title": "Report-Q2.pdf",
          "subtitle": "group #94",
          "jump_target": {
            "kind": "file",
            "channel_id": "group-94",
            "channel_type": "group",
            "file_id": "file-1"
          },
          "source": {
            "conversation_title": "产品内测群",
            "uploader_name": "Alice",
            "display_time": "10:20"
          }
        }
        """)

        XCTAssertEqual(item.displayModel.primaryText, "Report-Q2.pdf")
        XCTAssertEqual(item.displayModel.secondaryText, "产品内测群 · Alice · 10:20")
    }

    func testMessageExtraSearchInvalidationDecodesPayloadAndMatchesSearchResult() throws {
        let extra = try JSONDecoder().decode(RemoteMessageExtra.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "message_id": "msg-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 42,
          "extra_type": "moderation",
          "payload": {
            "search_invalidation": true,
            "event_type": "delete_for_all",
            "reason": "delete_for_all",
            "tenant_id": "tenant-1",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "message_id": "msg-1",
            "version": 7,
            "updated_at": "2026-06-27T01:02:03Z",
            "invalidation_key": "msg:group-1:42",
            "client_action": "remove"
          }
        }
        """.utf8))
        let result = try JSONDecoder().decode(RemoteTenantSearchResult.self, from: Data("""
        {
          "result_id": "message:msg-1",
          "type": "message",
          "title": "命中的消息",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "message_id": "msg-1"
          },
          "source": "tenant.messages"
        }
        """.utf8))

        let invalidation = try XCTUnwrap(SearchInvalidationEvent(
            payload: extra.payload,
            fallbackTenantID: extra.tenantID,
            fallbackChannelID: extra.channelID,
            fallbackChannelType: extra.channelType,
            fallbackChannelSeq: extra.channelSeq,
            fallbackMessageID: extra.messageID,
            fallbackUpdatedAt: extra.createdAt
        ))

        XCTAssertEqual(extra.channelSeq, 42)
        XCTAssertEqual(invalidation.tenantID, "tenant-1")
        XCTAssertEqual(invalidation.eventType, "delete_for_all")
        XCTAssertEqual(invalidation.invalidationKey, "msg:group-1:42")
        XCTAssertEqual(invalidation.channelSeq, 42)
        XCTAssertEqual(invalidation.version, 7)
        XCTAssertTrue(result.matchesSearchInvalidation(invalidation))
    }

    func testConversationSyncDecodesRemovedConversationsForSearchInvalidation() throws {
        let sync = try JSONDecoder().decode(RemoteConversationSyncData.self, from: Data("""
        {
          "version": 12,
          "conversations": [],
          "removed_conversations": [
            {
              "tenant_id": "tenant-1",
              "channel_id": "group-1",
              "channel_type": "group",
              "reason": "permission_lost",
              "version": 4,
              "updated_at": "2026-06-27T01:02:03Z"
            }
          ]
        }
        """.utf8))

        let removed = try XCTUnwrap(sync.removedConversations.first)
        let invalidation = SearchInvalidationEvent(removedConversation: removed)

        XCTAssertEqual(sync.version, 12)
        XCTAssertEqual(removed.channelID, "group-1")
        XCTAssertEqual(removed.channelType, "group")
        XCTAssertTrue(invalidation.isConversationRemoval)
        XCTAssertEqual(invalidation.channelID, "group-1")
    }

    func testForcedAuthPolicyRequiresRealNameWhenUserIsUnverified() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testForcedAuthPolicyRequiresPhoneWhenUserPhoneIsUnverified() {
        let policy = makeForcedAuthPolicy(requireRealName: false, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: true, realNameStatus: "verified", phoneVerified: false)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .phone)
    }

    func testForcedAuthPolicyPrioritizesPhoneWhenBothAreMissing() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: false)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .phone)
    }

    func testForcedAuthPolicyFallsThroughToRealNameAfterPhoneIsComplete() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testForcedAuthPolicyDoesNotPromptWhenNoRequirementIsEnabled() {
        let policy = makeForcedAuthPolicy(requireRealName: false, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: false)

        XCTAssertNil(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user))
    }

    func testForcedAuthPolicyTreatsPendingRealNameAsIncomplete() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "pending", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testGroupNicknameInputPolicyNormalizesNFCAndUnicodeWhitespace() throws {
        let normalized = try GroupNicknameInputPolicy.normalize("\u{3000}Cafe\u{301}\u{00A0}")

        XCTAssertEqual(normalized, "Café")
        XCTAssertEqual(normalized.unicodeScalars.count, 4)
    }

    func testGroupNicknameInputPolicyAllowsClearAndRejectsControlsAndMoreThan64Scalars() throws {
        XCTAssertEqual(try GroupNicknameInputPolicy.normalize(" \n "), "")
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize("昵称\n第二行")) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize("昵称\u{202E}覆盖")) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize(String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .tooLong)
        }
    }

    func testRemoteGroupMemberProfileDecodesFrozenContractAndGenerationFallback() throws {
        let profile = try JSONDecoder().decode(
            RemoteGroupMemberProfile.self,
            from: Data(
                #"""
                {
                  "contract_version": 1,
                  "group_id": "group-a",
                  "im_uid": "uid-1",
                  "group_nickname": "A 群昵称",
                  "raw_nickname": "全局昵称",
                  "display_name": "A 群昵称",
                  "display_name_source": "group_nickname",
                  "revision": 9,
                  "group_membership_generation": 12,
                  "updated_at": "2026-07-28T12:00:00Z"
                }
                """#.utf8
            )
        )

        XCTAssertEqual(profile.contractVersion, 1)
        XCTAssertEqual(profile.groupID, "group-a")
        XCTAssertEqual(profile.groupNickname, "A 群昵称")
        XCTAssertEqual(profile.rawNickname, "全局昵称")
        XCTAssertEqual(profile.displayNameSource, "group_nickname")
        XCTAssertEqual(profile.revision, 9)
        XCTAssertEqual(profile.groupMembershipGeneration, 12)
    }

    func testGroupMemberDisplayNameUsesGroupThenRemarkThenGlobalAndSelfSkipsRemark() {
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "",
                viewerRemarks: ["好友备注"],
                groupNickname: "群昵称",
                globalNickname: "全局昵称",
                stableIdentifier: "uid-1",
                isCurrentUser: false
            ),
            "群昵称"
        )
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "",
                viewerRemarks: ["不应显示的自我备注"],
                groupNickname: "我的群昵称",
                globalNickname: "我的全局昵称",
                stableIdentifier: "uid-me",
                isCurrentUser: true
            ),
            "我的群昵称"
        )
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "服务端展示名",
                viewerRemarks: ["本地旧备注"],
                groupNickname: "本地旧群昵称",
                globalNickname: "全局昵称",
                stableIdentifier: "uid-2",
                isCurrentUser: false
            ),
            "本地旧群昵称"
        )
    }

    func testGroupMemberDisplayNameSkipsBlankFieldsAndKeepsViewerRemarksIsolated() {
        for groupName in ["A 群昵称", "", " \n "] {
            for remark in ["查看者甲备注", "", " \t "] {
                for globalName in ["个人昵称", "", " \n "] {
                    let expected = [groupName, remark, globalName, "uid-peer"]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }!
                    XCTAssertEqual(GroupMemberDisplayNameResolver.resolve(
                        authoritativeDisplayName: "", viewerRemarks: [remark], groupNickname: groupName,
                        globalNickname: globalName, stableIdentifier: "uid-peer", isCurrentUser: false), expected)
                }
            }
        }
        for viewerRemark in ["查看者甲备注", "查看者乙备注"] {
            XCTAssertEqual(GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "旧服务端展示名", viewerRemarks: [viewerRemark], groupNickname: " ",
                globalNickname: "个人昵称", stableIdentifier: "uid-peer", isCurrentUser: false), viewerRemark)
        }
    }

	func testMessageEditAuthorityDecodesRevisionVersionAndCurrentMessage() throws {
		let response = try JSONDecoder().decode(RemoteExtraResponse.self, from: Data("""
		{
		  "extra": {
		    "tenant_id": "tenant-1", "message_id": "message-1", "channel_id": "u1:u2", "channel_type": "direct",
		    "channel_seq": 4, "version": 1700000000000001024, "operator_uid": "u1", "extra_type": "edit",
		    "payload": {"client_edit_id":"edit-1","edit_revision":2,"payload":{"text":"revision two","edit_revision":2}}
		  },
		  "message": {
		    "message_id":"message-1","channel_id":"u1:u2","channel_type":"direct","channel_seq":4,"from_uid":"u1",
		    "content_type":"text","status":"edited","payload":{"text":"revision two","edit_revision":2}
		  },
		  "duplicate": false
		}
		""".utf8))
		XCTAssertEqual(response.extra?.version, 1_700_000_000_000_001_024)
		XCTAssertEqual(response.extra?.editRevision, 2)
		XCTAssertEqual(response.extra?.dedupeKey.contains("1700000000000001024"), true)
		XCTAssertEqual(response.message?.editRevision, 2)
		XCTAssertEqual(response.message?.payload["text"]?.stringValue, "revision two")
		XCTAssertFalse(response.duplicate)
	}

	func testMessageEditExtraRequiresExplicitAuthoritativeEditRevision() throws {
		let extra = try JSONDecoder().decode(RemoteMessageExtra.self, from: Data("""
		{
		  "tenant_id":"tenant-1", "message_id":"message-legacy", "channel_id":"u1:u2", "channel_type":"direct",
		  "channel_seq":5, "version":1700000000000002048, "operator_uid":"u1", "extra_type":"edit",
		  "payload":{"payload":{"text":"legacy edit without revision"}}
		}
		""".utf8))
		XCTAssertEqual(extra.version, 1_700_000_000_000_002_048)
		XCTAssertEqual(extra.editRevision, 0)
	}

    private func decodeTenantSearchResult(_ json: String) throws -> RemoteTenantSearchResult {
        try JSONDecoder().decode(RemoteTenantSearchResult.self, from: Data(json.utf8))
    }

    private func makeForcedAuthPolicy(requireRealName: Bool, requirePhoneVerification: Bool) -> RemoteAppCurrentPolicy {
        RemoteAppCurrentPolicy(
            appID: "jht-ios-main",
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            cacheTTLSeconds: 60
        )
    }

    private func makeForcedAuthUser(
        id: String = "u1",
        userID: String = "",
        realNameVerified: Bool,
        realNameStatus: String,
        phoneVerified: Bool
    ) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            name: "测试用户",
            title: "",
            department: "",
            phone: phoneVerified ? "138****0000" : "",
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
    }
}
