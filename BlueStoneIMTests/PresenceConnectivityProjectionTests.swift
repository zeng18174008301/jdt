import XCTest
@testable import BlueStoneIM

final class PresenceConnectivityProjectionTests: XCTestCase {
    func testConnectivityEventAppliesAndOlderEventCannotRollback() {
        var projection = PresenceConnectivityProjection()
        let online = projection.consume(
            envelope(online: true, status: "online", revision: 5, generation: 9),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        guard case .applied(let value) = online else {
            return XCTFail("expected online event to apply, got \(online)")
        }
        XCTAssertEqual(value.uid, "u-1")
        XCTAssertEqual(value.online, true)
        XCTAssertEqual(value.presenceStatus, "online")

        let staleOffline = projection.consume(
            envelope(online: false, status: "offline", revision: 4, generation: 8),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        XCTAssertEqual(staleOffline, .ignoredStale)
        XCTAssertEqual(projection.value(forExactUID: "u-1")?.online, true)
    }

    func testSessionEpochWinsBeforeRevisionAndGeneration() {
        var projection = PresenceConnectivityProjection()
        _ = projection.consume(
            envelope(sessionEpoch: "epoch-b", online: true, status: "online", revision: 1, generation: 1),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )

        let olderEpoch = projection.consume(
            envelope(sessionEpoch: "epoch-a", online: false, status: "offline", revision: 99, generation: 99),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )

        XCTAssertEqual(olderEpoch, .ignoredStale)
        XCTAssertEqual(projection.value(forExactUID: "u-1")?.online, true)
    }

    func testSameWatermarkConflictRequiresReadbackAndRetainsCurrent() {
        var projection = PresenceConnectivityProjection()
        _ = projection.consume(
            envelope(online: true, status: "online", revision: 2, generation: 2),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )

        let conflict = projection.consume(
            envelope(online: false, status: "offline", revision: 2, generation: 2),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )

        XCTAssertEqual(conflict, .refetch(["u-1"], .connectivityConflict))
        XCTAssertEqual(projection.value(forExactUID: "u-1")?.online, true)
    }

    func testHiddenAndUnknownNeverBecomeOffline() {
        var projection = PresenceConnectivityProjection()
        let hidden = projection.consume(
            envelope(online: nil, status: "hidden", revision: 1, generation: 1),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        guard case .applied(let hiddenValue) = hidden else {
            return XCTFail("expected hidden event to apply, got \(hidden)")
        }
        XCTAssertNil(hiddenValue.online)
        XCTAssertEqual(hiddenValue.presenceStatus, "hidden")

        let unknown = projection.consume(
            envelope(online: false, status: "unknown", revision: 2, generation: 2),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        guard case .applied(let unknownValue) = unknown else {
            return XCTFail("expected unknown event to apply, got \(unknown)")
        }
        XCTAssertNil(unknownValue.online)
        XCTAssertEqual(unknownValue.presenceStatus, "unknown")
    }

    func testExplicitConnectivityStatusOverridesContradictoryCompatibilityBoolean() {
        var projection = PresenceConnectivityProjection()
        let offline = projection.consume(
            envelope(online: true, status: "offline", revision: 1, generation: 1),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        guard case .applied(let offlineValue) = offline else {
            return XCTFail("expected explicit offline event to apply, got \(offline)")
        }
        XCTAssertEqual(offlineValue.online, false)

        let online = projection.consume(
            envelope(online: false, status: "online", revision: 2, generation: 2),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        guard case .applied(let onlineValue) = online else {
            return XCTFail("expected explicit online event to apply, got \(online)")
        }
        XCTAssertEqual(onlineValue.online, true)
    }

    func testSameTenantViewerSwitchPurgesFenceAcrossAToBToA() {
        var projection = PresenceConnectivityProjection()
        _ = projection.consume(
            envelope(online: true, status: "online", revision: 9, generation: 9),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-a"
        )
        XCTAssertNotNil(projection.value(forExactUID: "u-1"))

        projection.bind(tenantID: "tenant-a", viewerID: "viewer-b")
        XCTAssertEqual(projection.viewerID, "viewer-b")
        XCTAssertNil(projection.value(forExactUID: "u-1"))

        _ = projection.consume(
            envelope(online: false, status: "offline", revision: 1, generation: 1),
            activeTenantID: "tenant-a",
            activeViewerID: "viewer-b"
        )
        projection.bind(tenantID: "tenant-a", viewerID: "viewer-a")
        XCTAssertEqual(projection.viewerID, "viewer-a")
        XCTAssertNil(projection.value(forExactUID: "u-1"))
    }

    func testForeignTenantAndMismatchedAliasesAreRejected() {
        var projection = PresenceConnectivityProjection()
        XCTAssertEqual(
            projection.consume(
                envelope(tenantID: "tenant-b", online: true, status: "online", revision: 1, generation: 1),
                activeTenantID: "tenant-a",
                activeViewerID: "viewer-a"
            ),
            .ignoredForeignTenant
        )

        var payload = envelope(online: true, status: "online", revision: 1, generation: 1).payload
        payload["subject_im_uid"] = .string("u-2")
        XCTAssertEqual(
            projection.consume(
                RealtimeEnvelope(type: "notification", requestID: nil, payload: payload),
                activeTenantID: "tenant-a",
                activeViewerID: "viewer-a"
            ),
            .refetch(["u-1"], .malformed)
        )
    }

    private func envelope(
        tenantID: String = "tenant-a",
        uid: String = "u-1",
        sessionEpoch: String = "epoch-a",
        online: Bool?,
        status: String,
        revision: Int64,
        generation: Int64,
        lastSeenAt: String = "2026-08-22T08:01:02.123Z"
    ) -> RealtimeEnvelope {
        var payload: [String: JSONValue] = [
            "event": .string("presence.connectivity.updated"),
            "event_type": .string("presence.connectivity.updated"),
            "tenant_id": .string(tenantID),
            "subject_type": .string("user"),
            "subject_id": .string(uid),
            "subject_im_uid": .string(uid),
            "im_uid": .string(uid),
            "session_epoch": .string(sessionEpoch),
            "presence_status": .string(status),
            "presence_revision": .int(Int(revision)),
            "realtime_generation": .int(Int(generation)),
            "last_seen_at": .string(lastSeenAt),
            "occurred_at": .string("2026-08-22T08:01:03.123Z")
        ]
        if let online {
            payload["online"] = .bool(online)
        }
        return RealtimeEnvelope(
            type: "notification",
            requestID: nil,
            payload: payload
        )
    }
}
