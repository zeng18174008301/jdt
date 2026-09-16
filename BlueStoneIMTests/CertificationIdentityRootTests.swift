import XCTest
@testable import BlueStoneIM

final class CertificationIdentityRootTests: XCTestCase {
    private let rootScope = CertificationPresentationRootScope(
        tenantID: "tenant-a",
        viewerID: "viewer-a",
        appID: "app1",
        sessionID: "session-a",
        sessionGeneration: 4,
        realtimeGeneration: 8
    )

    func testRootScopeIncludesRealtimeGenerationAndPurgesOnEpochChange() throws {
        var root = CertificationIdentityRoot(scope: rootScope)
        XCTAssertEqual(
            root.apply(
                summary: try makeSummary(generation: 7, revision: 3),
                subjectTenantID: "tenant-a",
                responseScope: rootScope,
                fresh: true
            ),
            .applied
        )
        XCTAssertEqual(
            root.presentation(forExactUID: "WXT00000001")?.visibleLabel,
            "企业导师"
        )

        let reconnected = CertificationPresentationRootScope(
            tenantID: "tenant-a",
            viewerID: "viewer-a",
            appID: "app1",
            sessionID: "session-a",
            sessionGeneration: 4,
            realtimeGeneration: 9
        )
        XCTAssertEqual(root.bind(reconnected), .cleared)
        XCTAssertNil(root.presentation(forExactUID: "WXT00000001"))
        XCTAssertTrue(root.subjectStates.isEmpty)
    }

    func testEventFenceIgnoresStaleAndForeignButInvalidatesNewGeneration() throws {
        var root = CertificationIdentityRoot(scope: rootScope)
        _ = root.apply(
            summary: try makeSummary(generation: 7, revision: 3),
            subjectTenantID: "tenant-a",
            responseScope: rootScope,
            fresh: true
        )

        XCTAssertEqual(
            root.invalidate(
                exactUID: "WXT00000001",
                tenantID: "tenant-a",
                generation: 6,
                revision: 2
            ),
            .ignoredStale
        )
        XCTAssertNotNil(root.presentation(forExactUID: "WXT00000001"))
        XCTAssertEqual(
            root.invalidate(
                exactUID: "WXT00000001",
                tenantID: "tenant-b",
                generation: 8,
                revision: 4
            ),
            .ignoredForeign
        )
        XCTAssertNotNil(root.presentation(forExactUID: "WXT00000001"))

        XCTAssertEqual(
            root.invalidate(
                exactUID: "WXT00000001",
                tenantID: "tenant-a",
                generation: 8,
                revision: 4
            ),
            .invalidated
        )
        XCTAssertEqual(
            root.presentation(forExactUID: "WXT00000001")?.visibleLabel,
            "企业导师"
        )
        XCTAssertTrue(
            try XCTUnwrap(root.state(forExactUID: "WXT00000001")).needsRefetch
        )
    }

    func testAuthoritativeOmissionClearsButMalformedResponseRetainsLastKnownGood() throws {
        var root = CertificationIdentityRoot(scope: rootScope)
        _ = root.apply(
            summary: try makeSummary(generation: 7, revision: 3),
            subjectTenantID: "tenant-a",
            responseScope: rootScope,
            fresh: true
        )
        XCTAssertEqual(
            root.applyAuthoritativeMissing(
                exactUID: "WXT00000001",
                responseScope: rootScope,
                fresh: true
            ),
            .cleared
        )
        XCTAssertNil(root.presentation(forExactUID: "WXT00000001"))
        XCTAssertTrue(
            try XCTUnwrap(root.state(forExactUID: "WXT00000001"))
                .authoritativeClear
        )

        _ = root.apply(
            summary: try makeSummary(generation: 8, revision: 4),
            subjectTenantID: "tenant-a",
            responseScope: rootScope,
            fresh: true
        )
        XCTAssertTrue(
            root.markMalformedForRefetch(exactUIDs: ["WXT00000001"])
        )
        XCTAssertEqual(
            root.presentation(forExactUID: "WXT00000001")?.visibleLabel,
            "企业导师"
        )
        XCTAssertTrue(
            try XCTUnwrap(root.state(forExactUID: "WXT00000001")).needsRefetch
        )
    }

    func testAuthorityRefreshKeepsPresentationWhileRefetchIsPending() throws {
        var root = CertificationIdentityRoot(scope: rootScope)
        _ = root.apply(
            summary: try makeSummary(generation: 7, revision: 3),
            subjectTenantID: "tenant-a",
            responseScope: rootScope,
            fresh: true
        )
        XCTAssertNotNil(root.presentation(forExactUID: "WXT00000001"))
        XCTAssertTrue(
            root.markMalformedForRefetch(exactUIDs: ["WXT00000001"])
        )
        XCTAssertEqual(
            root.presentation(forExactUID: "WXT00000001")?.visibleLabel,
            "企业导师"
        )
        XCTAssertTrue(
            try XCTUnwrap(root.state(forExactUID: "WXT00000001")).needsRefetch
        )
    }

    func testUIDBatchTrimsDeduplicatesPreservesOrderAndCapsAtOneHundred() {
        let values = ["  WXT2\n", "", "WXT1", "WXT2"]
            + (0..<110).map { "U\($0)" }
        let normalized = CertificationProfileUIDBatch.normalized(values)
        let normalizedAll = CertificationProfileUIDBatch.normalizedAll(values)

        XCTAssertEqual(normalized.prefix(3), ["WXT2", "WXT1", "U0"])
        XCTAssertEqual(normalized.count, 100)
        XCTAssertEqual(Set(normalized).count, normalized.count)
        XCTAssertEqual(normalizedAll.count, 112)
        XCTAssertEqual(Set(normalizedAll).count, normalizedAll.count)
    }

    func testMalformedRootInvalidationRetainsEveryTrackedUIDBeyondOneBatch() throws {
        var root = CertificationIdentityRoot(scope: rootScope)
        for index in 0..<105 {
            _ = root.apply(
                summary: try makeSummary(
                    generation: 7,
                    revision: 3,
                    exactUID: "WXT\(String(format: "%08d", index))"
                ),
                subjectTenantID: "tenant-a",
                responseScope: rootScope,
                fresh: true
            )
        }
        XCTAssertEqual(root.exactUIDs.count, 105)
        XCTAssertTrue(
            root.markMalformedForRefetch(exactUIDs: root.exactUIDs)
        )
        XCTAssertEqual(
            root.exactUIDs.filter {
                root.presentation(forExactUID: $0) != nil
                    && root.state(forExactUID: $0)?.needsRefetch == true
            }.count,
            105
        )
    }

    func testProfilesDecoderKeepsExactUIDWhenOneNestedSummaryIsMalformed() throws {
        let payload = #"""
        {
          "items":[
            {
              "im_uid":"WXT00000001",
              "user_id":"WXT00000001",
              "user_summary":{
                "schema":"user_summary.v2",
                "contract_version":1,
                "user_revision":9,
                "generations":{"identity":41,"certification":7},
                "im_uid":"WXT00000001",
                "user_id":"WXT00000001",
                "display_name":"王总",
                "display_name_source":"nickname",
                "raw_nickname":"王总",
                "avatar":{"url":"/avatar.png","version":"v1","source":"uploaded"},
                "certification":{"verified":true,"label":"企业导师","style":"tenant_certified_v1","revision":3}
              }
            },
            {
              "im_uid":"WXT00000002",
              "user_summary":{"schema":"wrong"}
            },
            {
              "im_uid":"WXT00000005",
              "user_id":"WXT00000005",
              "user_summary":{
                "schema":"user_summary.v2",
                "contract_version":1,
                "user_revision":9,
                "generations":{"identity":41,"certification":7},
                "im_uid":"WXT00000005",
                "user_id":"WXT00000099",
                "display_name":"错配身份",
                "display_name_source":"nickname",
                "raw_nickname":"错配身份",
                "avatar":{"url":"/avatar.png","version":"v1","source":"uploaded"},
                "certification":{"verified":true,"label":"企业导师","style":"tenant_certified_v1","revision":3}
              }
            },
            {
              "im_uid":"WXT00000003"
            }
          ],
          "missing_uids":["WXT00000004"],
          "max_uids":100
        }
        """#
        let response = try JSONDecoder().decode(
            RemoteUserProfilesResponse.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(response.items.map(\.imUID), [
            "WXT00000001", "WXT00000002", "WXT00000005", "WXT00000003"
        ])
        guard case .authoritative(let summary) =
            response.items[0].userSummaryProjection else {
            return XCTFail("expected authoritative summary")
        }
        XCTAssertEqual(summary.certification?.label, "企业导师")
        XCTAssertEqual(response.items[1].userSummaryProjection, .malformed)
        XCTAssertEqual(response.items[2].userSummaryProjection, .malformed)
        XCTAssertEqual(
            response.items[3].userSummaryProjection,
            .authoritativeOmission
        )
    }

    func testProfilesDecoderRejectsDuplicateOrOverlappingUIDs() {
        for payload in [
            #"{"items":[{"im_uid":"U1"},{"im_uid":"U1"}],"missing_uids":[],"max_uids":100}"#,
            #"{"items":[{"im_uid":"U1"}],"missing_uids":["U1"],"max_uids":100}"#
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    RemoteUserProfilesResponse.self,
                    from: Data(payload.utf8)
                )
            )
        }
    }

    func testSixteenCharacterLabelAndLongNameRemainAccessibleButSeventeenFailsClosed() throws {
        let sixteenCharacterLabel = "一二三四五六七八九十一二三四五六"
        XCTAssertEqual(sixteenCharacterLabel.count, 16)
        let accepted = try XCTUnwrap(
            CertificationPresentation(
                certification: try XCTUnwrap(
                    makeSummary(
                        generation: 7,
                        revision: 3,
                        label: sixteenCharacterLabel
                    ).certification
                ),
                generation: 7
            )
        )
        XCTAssertEqual(accepted.visibleLabel, sixteenCharacterLabel)
        XCTAssertEqual(
            accepted.accessibilityLabel,
            "由本企业认证：\(sixteenCharacterLabel)"
        )

        let seventeenCharacterLabel = sixteenCharacterLabel + "七"
        XCTAssertEqual(seventeenCharacterLabel.count, 17)
        XCTAssertNil(
            CertificationPresentation(
                certification: try XCTUnwrap(
                    makeSummary(
                        generation: 7,
                        revision: 4,
                        label: seventeenCharacterLabel
                    ).certification
                ),
                generation: 7
            )
        )
    }

    func testProfileRequestFenceCoalescesRemountAndUsesBoundedRetryBackoff() throws {
        var fence = CertificationProfileRequestFence()
        fence.bind(rootScope)
        let first = try XCTUnwrap(
            fence.begin(exactUIDs: ["WXT00000001"], now: Date(timeIntervalSince1970: 100))
        )
        XCTAssertNil(
            fence.begin(exactUIDs: ["WXT00000001"], now: Date(timeIntervalSince1970: 100))
        )
        XCTAssertTrue(fence.queueableUIDs(from: ["WXT00000001"]).isEmpty)

        var retryable = fence.markFailed(
            exactUIDs: first.exactUIDs,
            wave: first.wave,
            kind: .transient,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(retryable, ["WXT00000001"])
        XCTAssertTrue(
            fence.eligibleUIDs(
                from: retryable,
                now: Date(timeIntervalSince1970: 100.5)
            ).isEmpty
        )

        var now = Date(timeIntervalSince1970: 101)
        for expectedAttempt in 2...CertificationProfileRequestFence.maximumAttemptsPerWave {
            let retry = try XCTUnwrap(fence.begin(exactUIDs: retryable, now: now))
            retryable = fence.markFailed(
                exactUIDs: retry.exactUIDs,
                wave: retry.wave,
                kind: .transient,
                now: now
            )
            if expectedAttempt < CertificationProfileRequestFence.maximumAttemptsPerWave {
                XCTAssertEqual(retryable, ["WXT00000001"])
            } else {
                XCTAssertTrue(retryable.isEmpty)
            }
            now = now.addingTimeInterval(pow(2, Double(expectedAttempt - 1)))
        }
        XCTAssertTrue(fence.queueableUIDs(from: ["WXT00000001"]).isEmpty)
    }

    func testProfileRequestFenceTerminalFailureAndScopeSwitchFailClosed() throws {
        var fence = CertificationProfileRequestFence()
        fence.bind(rootScope)
        let request = try XCTUnwrap(fence.begin(exactUIDs: ["U401", "U404"], now: .now))
        XCTAssertTrue(
            fence.markFailed(
                exactUIDs: request.exactUIDs,
                wave: request.wave,
                kind: .terminal,
                now: .now
            ).isEmpty
        )
        XCTAssertTrue(fence.queueableUIDs(from: request.exactUIDs).isEmpty)

        let nextScope = CertificationPresentationRootScope(
            tenantID: "tenant-b",
            viewerID: "viewer-b",
            appID: "app1",
            sessionID: "session-b",
            sessionGeneration: 5,
            realtimeGeneration: 0
        )
        fence.bind(nextScope)
        XCTAssertTrue(fence.phases.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(fence.begin(exactUIDs: ["U401"], now: .now)).exactUIDs,
            ["U401"]
        )
    }

    func testProfileRequestFailureClassificationBoundsAuthNotFoundAndServerRetries() {
        for status in [401, 404, 422] {
            XCTAssertEqual(
                AppState.certificationProfileFetchFailureKind(
                    IMAPIError.httpStatus(status, message: "terminal")
                ),
                .terminal
            )
        }
        for status in [408, 429, 500, 502, 503, 599] {
            XCTAssertEqual(
                AppState.certificationProfileFetchFailureKind(
                    IMAPIError.httpStatus(status, message: "retryable")
                ),
                .transient
            )
        }
        XCTAssertEqual(
            AppState.certificationProfileFetchFailureKind(
                IMAPIError.unauthorized("expired")
            ),
            .terminal
        )
        XCTAssertEqual(
            AppState.certificationProfileFetchFailureKind(
                IMAPIError.rateLimited(
                    code: "rate_limited",
                    message: "slow down",
                    retryAfterSeconds: 1,
                    lockedUntil: nil
                )
            ),
            .transient
        )
        XCTAssertEqual(
            AppState.certificationProfileFetchFailureKind(
                URLError(.networkConnectionLost)
            ),
            .transient
        )
    }

    @MainActor
    func testProfileRequestBrokerCoalescesSameLogicalWaveAcrossScenes() async throws {
        let response = try JSONDecoder().decode(
            RemoteUserProfilesResponse.self,
            from: Data(#"{"items":[],"missing_uids":["U1"],"max_uids":100}"#.utf8)
        )
        var requestCount = 0
        let operation: @MainActor ([String]) async throws -> RemoteUserProfilesResponse = { requestedUIDs in
            requestCount += 1
            XCTAssertEqual(requestedUIDs, ["U1"])
            try await Task.sleep(nanoseconds: 20_000_000)
            return response
        }
        let first = Task { @MainActor in
            try await CertificationProfileRequestBroker.shared.response(
                scope: rootScope,
                exactUIDs: ["U1"],
                operation: operation
            )
        }
        let second = Task { @MainActor in
            try await CertificationProfileRequestBroker.shared.response(
                scope: rootScope,
                exactUIDs: [" U1 "],
                operation: operation
            )
        }
        let responses = try await [first.value, second.value]
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(responses.map(\.missingUIDs), [["U1"], ["U1"]])
    }

    @MainActor
    func testProfileRequestBrokerCoalescesOverlappingUIDWavesWithoutDuplicatePOST() async throws {
        var requestedWaves: [[String]] = []
        let operation: @MainActor ([String]) async throws -> RemoteUserProfilesResponse = { requestedUIDs in
            requestedWaves.append(requestedUIDs)
            try await Task.sleep(nanoseconds: 30_000_000)
            let missing = requestedUIDs
                .map { "\"\($0)\"" }
                .joined(separator: ",")
            return try JSONDecoder().decode(
                RemoteUserProfilesResponse.self,
                from: Data(
                    "{\"items\":[],\"missing_uids\":[\(missing)],\"max_uids\":100}".utf8
                )
            )
        }
        let first = Task { @MainActor in
            try await CertificationProfileRequestBroker.shared.response(
                scope: rootScope,
                exactUIDs: ["U1", "U2"],
                operation: operation
            )
        }
        for _ in 0..<20 where requestedWaves.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(requestedWaves, [["U1", "U2"]])
        let second = Task { @MainActor in
            try await CertificationProfileRequestBroker.shared.response(
                scope: rootScope,
                exactUIDs: ["U2", "U3"],
                operation: operation
            )
        }

        let firstResponse = try await first.value
        let secondResponse = try await second.value
        XCTAssertEqual(Set(firstResponse.missingUIDs), ["U1", "U2"])
        XCTAssertEqual(Set(secondResponse.missingUIDs), ["U2", "U3"])
        XCTAssertEqual(requestedWaves.count, 2)
        XCTAssertEqual(requestedWaves.flatMap { $0 }.filter { $0 == "U2" }.count, 1)
        XCTAssertTrue(requestedWaves.contains(["U1", "U2"]))
        XCTAssertTrue(requestedWaves.contains(["U3"]))
    }

    private func makeSummary(
        generation: Int64,
        revision: Int64,
        label: String = "企业导师",
        exactUID: String = "WXT00000001"
    ) throws -> UserSummaryV2 {
        try UserSummaryV2(
            userRevision: 9,
            generations: .init(identity: 41, certification: generation),
            imUID: exactUID,
            userID: exactUID,
            displayName: String(repeating: "超长姓名", count: 12),
            displayNameSource: "nickname",
            rawNickname: String(repeating: "超长姓名", count: 12),
            avatar: .init(
                url: "/avatars/user.png",
                version: "v1",
                source: "uploaded"
            ),
            certification: .init(
                verified: true,
                label: label,
                style: certificationPresentationStyleToken,
                revision: revision
            )
        )
    }
}
