import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
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
}
