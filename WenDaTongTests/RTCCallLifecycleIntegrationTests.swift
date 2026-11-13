import XCTest
import AVFoundation
import Combine
import SwiftUI
import UIKit
import Vision // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112
@testable import WenDaTong

@MainActor
final class RTCDuplicateRingingHandlerTests: XCTestCase {
    private let callID = "fixture-ringing-call"

    func testSameCallRealtimeReplayDoesNotRejectOrEndPresentedCall() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, .ringing)
        XCTAssertTrue(state.callStore.hasTruthfulCall)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertTrue(system.ends.isEmpty)

        // Enter the production realtime dispatcher, not receiveIncomingVoiceCall.
        state.debugHandleRealtimeEnvelopeForTesting(ringing(version: 2))
        try await drainTerminalCompensation(state)

        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, callID)
        XCTAssertTrue(system.ends.isEmpty, "same-ID replay must not issue CallKit endCall")
        XCTAssertTrue(transport.rejectPaths.isEmpty, "same-ID replay must not POST /reject")
    }

    func testRealtimeThenHTTPReplayUsesSharedHandlerWithoutRejectingSameCall() async throws {
        XCTAssertFalse(JHTRuntimeFeatureFlags.disableRTCRuntime,
                       "enable RTC runtime for actual HTTP refresh entrypoint coverage")
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        XCTAssertTrue(state.callStore.hasTruthfulCall)

        // Runs actual API GET -> RemoteRTCCallEvent decoding -> shared handler -> ACK.
        await state.refreshRTCCallEventsForTesting()
        try await drainTerminalCompensation(state)

        XCTAssertTrue(transport.paths.contains("/api/rtc/calls/events"))
        XCTAssertTrue(transport.paths.contains("/api/rtc/calls/events/ack"))
        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
    }

    func testDelayedRingingDoesNotRejectCallAfterRealAcceptAndJoin() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        state.acceptIncomingVoiceCall()
        let deadline = Date().addingTimeInterval(5)
        while !transport.participantGate.entered, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(transport.participantGate.entered)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertNil(state.incomingVoiceCall)
        state.debugHandleRealtimeEnvelopeForTesting(ringing(version: 2))
        try await drainTerminalCompensation(state)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        state.endActiveVoiceCall()
        transport.participantGate.release()
        while (state.activeVoiceCall != nil || state.incomingCallAnswerMode != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingCallAnswerMode)
    }

    func testDifferentCallStillReceivesBusyRejectWithoutEndingCurrentIncomingCall() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        state.debugHandleRealtimeEnvelopeForTesting(ringing(callID: "fixture-competing-call"))
        try await drainTerminalCompensation(state)

        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, callID)
        XCTAssertEqual(system.ends.map(\.callID), ["fixture-competing-call"])
        XCTAssertEqual(system.ends.map(\.reason), ["client_busy"])
        XCTAssertEqual(transport.rejectPaths, ["/api/rtc/calls/fixture-competing-call/reject"])
    }

    func testReceiveIncomingDirectlyHasSameCallGuardButIsNotSharedHandlerCoverage() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        state.receiveIncomingVoiceCall(from: first.caller, callID: callID,
                                       roomID: "fixture-room", stateVersion: 2,
                                       systemOwnsRingtone: true)
        try await drainTerminalCompensation(state)
        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
    }

    private func drainTerminalCompensation(_ state: AppState) async throws {
        // enqueueRTCTerminalCompensation inserts in-flight synchronously BEFORE
        // scheduling its Task. This avoids an arbitrary negative-request sleep.
        let deadline = Date().addingTimeInterval(2)
        while state.rtcTerminalCompensationsInFlightCountForTesting > 0 {
            if Date() >= deadline { throw RingingFixtureError.compensationDidNotDrain }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeFixture() -> (AppState, RecordingRingingSystem, RecordingRingingHTTPTransport) {
        let transport = RecordingRingingHTTPTransport()
        let system = RecordingRingingSystem(presented: [callID])
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                              tenantBase: URL(string: "https://tenant.example.test")!,
                              imBase: URL(string: "https://im.example.test")!,
                              httpTransport: transport, wireCodec: JSONWireCodec())
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
                             videoMediaClient: NoopVideoMediaClient(), voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true },
                             apiContextOverride: IMAPIContext(
                                platformToken: "fixture-platform-token", accountID: "fixture-account",
                                tenantID: "fixture-tenant", imUID: "fixture-callee",
                                imToken: "fixture-im-token", platformAuthSession: nil,
                                tenantAuthSession: nil, appID: "ios-main", deviceID: "fixture-device"))
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(maxBytes: 20971520, maxMB: 20, source: "test",
            messageRecallMaxMinutes: 120, voiceCallEnabled: true, videoCallEnabled: true,
            readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false)
        state.setCurrentUser(IMUser(id: "fixture-callee", name: "Fixture callee", title: "",
                                   department: "", phone: "", email: "", status: "在线",
                                   enterprise: "", avatarSeed: 0, badges: [])) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        return (state, system, transport)
    }

    private func ringing(callID: String? = nil, version: Int = 1) -> RealtimeEnvelope {
        RealtimeEnvelope(type: "rtc.call.ringing", requestID: UUID().uuidString, payload: [
            "call_id": .string(callID ?? self.callID), "status": .string("ringing"),
            "caller_uid": .string("fixture-caller"), "callee_uid": .string("fixture-callee"),
            "room_id": .string("fixture-room"), "state_version": .string(String(version)),
            "call_type": .string("audio")
        ])
    }
}

private enum RingingFixtureError: Error { case unexpectedRequest, compensationDidNotDrain }

private final class RecordingRingingHTTPTransport: HTTPTransport, @unchecked Sendable {
    let participantGate = SetupRaceGate()
    private let configurationTransport = SetupRaceHTTPTransport(status: "ringing", deviceAuthority: false)
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var paths: [String] { lock.withLock { captured.compactMap { $0.url?.path } } }
    var rejectPaths: [String] { paths.filter { $0.hasSuffix("/reject") } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock { captured.append(request) }
        let path = request.url?.path ?? ""
        let body: String
        if path == "/api/rtc/calls/events", request.httpMethod == "GET" {
            body = #"{"ok":true,"data":{"events":[{"id":"fixture-event","notification_id":"fixture-notification","type":"rtc.call.ringing","payload":{"call_id":"fixture-ringing-call","status":"ringing","caller_uid":"fixture-caller","callee_uid":"fixture-callee","room_id":"fixture-room","state_version":2,"call_type":"audio"}}]}}"#
        } else if path == "/api/rtc/calls/fixture-ringing-call/accept" {
            body = #"{"ok":true,"data":{"call":{"id":"fixture-ringing-call","room_id":"fixture-room","status":"accepted","caller_uid":"fixture-caller","callee_uid":"fixture-callee","call_type":"audio","state_version":2},"rtc_token":"fixture-rtc-token"}}"#
        } else if path == "/api/rtc/rooms/fixture-room/join" {
            body = #"{"ok":true,"data":{"room_id":"fixture-room","rtc_token":"fixture-rtc-token","media":{"owt_base_url":"https://rtc.example.test","ice_servers":[]},"participants":[]}}"#
        } else if path == "/api/rtc/rooms/fixture-room/participants" {
            await participantGate.wait()
            body = #"{"ok":true,"data":{"participants":[]}}"#
        } else if path == "/api/tenant/files/config" || path == "/api/rtc/provider" {
            return try await configurationTransport.data(for: request)
        } else if request.httpMethod == "POST",
                  path == "/api/rtc/calls/events/ack" || path.hasSuffix("/reject") || path.hasSuffix("/hangup") {
            body = #"{"ok":true,"data":{}}"#
        } else { throw RingingFixtureError.unexpectedRequest }
        return HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true,
                                   statusCode: 200).resolvingResponseURL(request.url)
    }
    func upload(for request: URLRequest, from data: Data,
                delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw RingingFixtureError.unexpectedRequest
    }
}

final class RecordingRingingSystem: VoiceCallSystemIntegrating, @unchecked Sendable {
    struct End: Equatable { let callID: String; let reason: String }
    let events = AsyncStream<VoiceCallSystemEvent> { $0.finish() }
    private let lock = NSLock()
    private var presented: Set<String>
    private var recordedEnds: [End] = []
    var ends: [End] { lock.withLock { recordedEnds } }
    init(presented: Set<String>) { self.presented = presented }
    func start() {}
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool { false }
    func setMuted(callID: String, isMuted: Bool) {}
    func hasPresentedCall(callID: String) -> Bool { lock.withLock { presented.contains(callID) } }
    func clearPresentedCall(callID: String) { lock.withLock { _ = presented.remove(callID) } }
    func endCall(callID: String, reason: String) {
        lock.withLock {
            recordedEnds.append(End(callID: callID, reason: reason))
            presented.remove(callID)
        }
    }
}

@MainActor
final class RTCCallSetupReconciliationTests: XCTestCase {
    func testRingingListStartedBeforeVoiceSetupCannotCancelOwnedJoin() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: true, suspendCreate: false)
    }

    func testAcceptedListStartedBeforeVoiceSetupCannotHangupOwnedJoin() async throws {
        try await assertListRace(status: "accepted", deviceAuthority: true, suspendCreate: false)
    }

    func testListReturningBeforeCreateResponseDoesNotCancelStartingCall() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: true, suspendCreate: true)
    }

    func testCurrentPublicListWithoutDeviceAuthorityDoesNotTakeColdLaunchPath() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: false, suspendCreate: false)
    }

    func testTrueColdLaunchStillCancelsOwnedDeviceRingingCall() async throws {
        try await assertColdLaunch(status: "ringing", action: "cancel")
    }

    func testTrueColdLaunchStillHangsUpOwnedDeviceAcceptedCall() async throws {
        try await assertColdLaunch(status: "accepted", action: "hangup")
    }

    private func assertListRace(status: String, deviceAuthority: Bool, suspendCreate: Bool) async throws {
        XCTAssertFalse(JHTRuntimeFeatureFlags.disableRTCRuntime)
        let transport = SetupRaceHTTPTransport(status: status, deviceAuthority: deviceAuthority)
        let (state, system, peer) = makeFixture(transport)
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "setup-race-exit",
            counts: transport.acceptancePathCounts.merging(["hardware.inputAvailable": AVAudioSession.sharedInstance().isInputAvailable ? 1 : 0]) { first, _ in first }) }
        // A refresh already in flight is allowed by the periodic loop's starting
        // guard. The list response is resumed only after real create/join begins.
        let refresh = Task { await state.refreshRTCCallsForTesting() }
        do {
            try await eventually { transport.listGate.entered }
            XCTAssertFalse(state.isStartingVoiceCall)
            if !suspendCreate { transport.createGate.release() }
            state.startOutgoingVoiceCall(to: peer)
            try await eventually { suspendCreate ? transport.createGate.entered : transport.joinGate.entered }
            XCTAssertTrue(state.isStartingVoiceCall)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 1)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, suspendCreate ? 0 : 1)
            XCTAssertNil(state.callStore.activeLifecycleSnapshot)
            XCTAssertNil(state.activeVoiceCall)
            transport.listGate.release()
            await refresh.value
            try await eventually { state.rtcTerminalCompensationsInFlightCountForTesting == 0 }
            XCTAssertTrue(system.ends.isEmpty, "a current local setup is not a cold launch orphan")
            XCTAssertTrue(transport.terminalPaths.isEmpty, "list reconciliation must not cancel or hang up the setup")
            // Complete the original real setup; a fixture failure must not leave
            // its continuations, audio session or outgoing watchdog alive.
            transport.createGate.release()
            transport.joinGate.release()
            try await eventually { !state.isStartingVoiceCall }
            XCTAssertEqual(state.activeVoiceCall?.callID, "setup-race-call")
            state.endActiveVoiceCall()
            try await eventually { state.activeVoiceCall == nil && !state.isEndingActiveCall }
        } catch {
            transport.listGate.release()
            transport.createGate.release()
            transport.joinGate.release()
            await refresh.value
            try? await eventually { !state.isStartingVoiceCall }
            state.endActiveVoiceCall()
            try? await eventually { state.activeVoiceCall == nil && !state.isEndingActiveCall }
            throw error
        }
    }

    private func assertColdLaunch(status: String, action: String) async throws {
        let transport = SetupRaceHTTPTransport(status: status, deviceAuthority: true)
        let (state, system, _) = makeFixture(transport)
        transport.listGate.release()
        await state.refreshRTCCallsForTesting()
        try await eventually { state.rtcTerminalCompensationsInFlightCountForTesting == 0 }
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(transport.terminalPaths, ["/api/rtc/calls/setup-race-call/\(action)"])
        XCTAssertEqual(system.ends.map(\.callID), ["setup-race-call"])
        XCTAssertNil(state.activeVoiceCall)
    }

    private func makeFixture(_ transport: SetupRaceHTTPTransport) -> (AppState, RecordingRingingSystem, IMUser) {
        let system = RecordingRingingSystem(presented: [])
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                              tenantBase: URL(string: "https://tenant.example.test")!,
                              imBase: URL(string: "https://im.example.test")!, httpTransport: transport)
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
                             videoMediaClient: NoopVideoMediaClient(), voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true },
                             apiContextOverride: IMAPIContext(
                                platformToken: "fixture-platform-token", accountID: "fixture-account",
                                tenantID: "fixture-tenant", imUID: "fixture-caller", imToken: "fixture-im-token",
                                platformAuthSession: nil, tenantAuthSession: nil,
                                appID: "ios-main", deviceID: "fixture-device"))
        func user(_ id: String) -> IMUser {
            IMUser(id: id, name: id, title: "", department: "", phone: "", email: "",
                   status: "在线", enterprise: "", avatarSeed: 0, badges: [])
        }
        let peer = user("fixture-callee")
        state.setAuthenticated(true) // Real refresh/end-operation authenticated precondition, before fixture business state.
        state.setCurrentUser(user("fixture-caller")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(maxBytes: 20971520, maxMB: 20, source: "test",
            messageRecallMaxMinutes: 120, voiceCallEnabled: true, videoCallEnabled: true,
            readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false)
        return (state, system, peer)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw SetupRaceError.conditionTimedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private enum SetupRaceError: Error { case conditionTimedOut, unexpectedRequest }

final class SetupRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                didEnter = true
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private final class SetupRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    let listGate = SetupRaceGate()
    let createGate = SetupRaceGate()
    let joinGate = SetupRaceGate()
    private let status: String
    private let deviceAuthority: Bool
    private let lock = NSLock()
    private var paths: [String] = []
    var acceptancePathCounts: [String: Int] {
        lock.withLock { Dictionary(paths.map { ($0, 1) }, uniquingKeysWith: +) }
    }
    var terminalPaths: [String] {
        lock.withLock { paths.filter { $0.hasSuffix("/cancel") || $0.hasSuffix("/hangup") } }
    }
    init(status: String, deviceAuthority: Bool) {
        self.status = status
        self.deviceAuthority = deviceAuthority
    }
    private func call(status: String) -> [String: Any] {
        var value: [String: Any] = ["id": "setup-race-call", "room_id": "setup-race-room",
            "caller_uid": "fixture-caller", "callee_uid": "fixture-callee", "status": status,
            "call_type": "audio", "state_version": 1]
        // Explicit synthetic activation condition: current server's public JSON
        // omits device authority. This case is not evidence of the user's live A/B.
        if deviceAuthority { value["caller_device"] = ["device_id": "fixture-device"] }
        return value
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock { paths.append(path) }
        let data: [String: Any]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/api/rtc/calls"):
            await listGate.wait()
            data = ["calls": [call(status: status)]]
        case ("POST", "/api/rtc/calls"):
            await createGate.wait()
            data = ["call": call(status: "ringing"), "rtc_token": "fixture-rtc-token"]
        case (_, "/api/rtc/rooms/setup-race-room/join"):
            await joinGate.wait()
            data = ["room_id": "setup-race-room", "rtc_token": "fixture-rtc-token",
                    "media": ["owt_base_url": "https://rtc.example.test", "ice_servers": []], "participants": []]
        case (_, "/api/tenant/files/config"):
            data = ["file_upload_max_bytes": 20971520, "max_mb": 20, "source": "test",
                    "message_recall_max_minutes": 120, "voice_call_enabled": true,
                    "video_call_enabled": true, "read_receipts_enabled": true, "group_admin_delete_message_enabled": false]
        case (_, "/api/rtc/provider"):
            data = ["call_types": ["audio", "video"], "voice_call_enabled": true,
                    "video_call_enabled": true, "video_supported": true, "capabilities_version": "video-call-v1",
                    "media_plane_configured": true, "ice_servers_configured": true]
        default:
            guard path.hasSuffix("/cancel") || path.hasSuffix("/hangup") else {
                throw SetupRaceError.unexpectedRequest
            }
            data = [:]
        }
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]),
            isHTTPResponse: true, statusCode: 200).resolvingResponseURL(request.url)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw SetupRaceError.unexpectedRequest
    }
}

// WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
extension DomainStoreTests {
    func testCallArchiveDeviceChangeRejectsLateFallbackAndKeepsLiveBinding() async throws {
        var context = callArchiveTestContext()
        context.tenantAuthSession = IMStoredAuthSession(
            sessionID: "sess_call_archive_fixture", refreshToken: "initial-refresh", tokenType: "im",
            tenantID: context.tenantID ?? "", accountID: context.accountID ?? "", appID: context.appID,
            deviceID: context.deviceID, clientType: "ios"
        )
        let originalScope = try LocalMessageScope(context: context)
        var replacement = context
        replacement.deviceID = UUID().uuidString
        let replacementScope = try LocalMessageScope(context: replacement)
        let transport = FakeHTTPTransport(results: [
            try callArchiveRefreshResult(context, token: "same-device-token"),
            try callArchiveRefreshResult(replacement, token: "new-device-token"),
        ])
        let entered = expectation(description: "old device reached its blocked fallback")
        let archived = callArchiveTestRecord("old-device", title: "Crimson Observatory")
        let current = callArchiveTestRecord("new-device", title: "Ivory Lighthouse")
        let oldFallback = SnapshotCache().scopeKey(for: context)
        let newFallback = SnapshotCache().scopeKey(for: replacement)
        let archive = FencedCallArchive(
            rows: [oldFallback: [archived], newFallback: [current]], blockedScope: oldFallback, entered: entered
        )
        defer { archive.release() }
        let (state, defaults) = try makeCallArchiveScopeState(context: context, archive: archive, transport: transport)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let stableKey = state.callRecordDataScopeKey(for: context)
        XCTAssertEqual(stableKey, state.callRecordDataScopeKey(for: replacement))
        XCTAssertNotEqual(oldFallback, newFallback)

        // Seed the already-open history, as cold login does, before testing the online refresh.
        state.bindCallRecordPersistence(for: context)
        await fulfillment(of: [entered], timeout: 4)
        let pending = callArchiveTestRecord("same-scope-visible")
        let originalRollback = state.callStore.makeCallRecordRollback(callID: "same-scope-visible")
        state.calls = [pending]
        let sameScopeRenewed = await state.refreshStoredAuthSessionIfNeeded(
            reason: "foreground", silent: true, persistenceDefaults: defaults
        )
        XCTAssertTrue(sameScopeRenewed)
        XCTAssertEqual(state.apiContext.imToken, "same-device-token")
        XCTAssertEqual(state.apiContext.deviceID, context.deviceID)
        XCTAssertEqual(state.apiContext.tenantID, context.tenantID)
        XCTAssertEqual(try LocalMessageScope(context: state.apiContext), originalScope)
        XCTAssertTrue(state.callStore.hasCallRecordPersistenceBinding(for: originalScope))
        XCTAssertEqual(state.callStore.calls, [pending])
        originalRollback()
        XCTAssertTrue(state.callStore.calls.isEmpty, "The original in-flight binding still owns rollback")
        XCTAssertTrue(archive.writes.isEmpty)
        let lateRollback = state.callStore.makeCallRecordRollback(callID: "new-device")

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let mounted = expectation(description: "production RTC history appeared before the device replacement")
        mounted.assertForOverFulfill = false
        let host = UIHostingController(rootView: NavigationStackCompat {
            RTCEntryView().onAppear { mounted.fulfill() }
        }.appStateEnvironment(state))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        await fulfillment(of: [mounted], timeout: 2)

        let restored = expectation(description: "replacement device restores its admitted fallback")
        var visible: [CallRecord] = []
        let observation = state.callStore.$calls.dropFirst().sink { records in
            visible += records
            if records == [current] { restored.fulfill() }
        }
        defer { observation.cancel() }
        let oldScopeRenewed = await state.refreshStoredAuthSessionIfNeeded(
            reason: "foreground", silent: true, persistenceDefaults: defaults
        )
        // The old caller is fenced even though the server replacement was committed.
        XCTAssertFalse(oldScopeRenewed)
        XCTAssertEqual(state.apiContext.deviceID, replacement.deviceID)
        XCTAssertEqual(state.apiContext.imToken, "new-device-token")
        XCTAssertEqual(try LocalMessageScope(context: state.apiContext), replacementScope)
        let committedContext = IMAPIContext.load(defaults: defaults, sessionStore: state.protectedSessionStore)
        XCTAssertEqual(committedContext.deviceID, replacement.deviceID)
        XCTAssertEqual(try LocalMessageScope(context: committedContext), replacementScope)
        XCTAssertTrue(state.callStore.calls.isEmpty)
        XCTAssertTrue(state.callStore.hasCallRecordPersistenceBinding(for: replacementScope))

        archive.release()
        await fulfillment(of: [restored], timeout: 4)
        let deadline = Date().addingTimeInterval(4)
        var frame = await callHistoryFrame(in: window, hostedView: host.view, current: current, retired: archived)
        while let titles = frame.titles, !titles.current, Date() < deadline {
            try await Task.sleep(nanoseconds: 80_000_000)
            frame = await callHistoryFrame(in: window, hostedView: host.view, current: current, retired: archived)
        }
        if let image = frame.image { add(snapshotAttachment(image, name: "call-archive-mounted-history-after-refresh")) }
        let diagnostic = "\(frame.diagnostic); scene=\(scene.activationState.rawValue); key=\(window.isKeyWindow); "
            + "host=\(host.view.bounds); window=\(window.bounds); store=\(state.callStore.calls.map(\.id))"
        let readback = XCTAttachment(string: diagnostic)
        readback.name = "call-archive-mounted-history-readback"
        readback.lifetime = .keepAlways
        add(readback)
        XCTAssertTrue(host.view.window === window)
        XCTAssertFalse(window.isHidden, diagnostic)
        if let titles = frame.titles {
            XCTAssertTrue(titles.current, diagnostic)
            XCTAssertFalse(titles.retired, diagnostic)
        } else {
            XCTFail("Mounted history screenshot/OCR evidence unavailable. \(diagnostic)")
        }
        lateRollback()
        XCTAssertEqual(state.callStore.calls, [current])
        XCTAssertFalse(visible.contains(archived))
        XCTAssertEqual(archive.loadedScopes.filter { $0 == stableKey }.count, 2)
        XCTAssertEqual(archive.writes, [.init(scope: stableKey, records: [current])])
        XCTAssertEqual(archive.records(for: oldFallback), [archived])
        XCTAssertEqual(archive.records(for: newFallback), [current])
        let expectedPath = "/api/platform/tenants/\(context.tenantID ?? "")/session/refresh"
        XCTAssertEqual(transport.requests().compactMap { $0.url?.path }, [expectedPath, expectedPath])
    }

    func testCallArchiveExitRejectsLateRestoreAndKeepsAdmittedRecord() async throws {
        let context = callArchiveTestContext()
        let archived = callArchiveTestRecord("archived")
        let accepted = callArchiveTestRecord("accepted")
        let entered = expectation(description: "original archive read is pending")
        let archive = FencedCallArchive(rows: [:], blockedScope: nil, entered: entered)
        defer { archive.release() }
        let (state, defaults) = try makeCallArchiveScopeState(context: context, archive: archive)
        let stableKey = state.callRecordDataScopeKey(for: context)
        archive.seed([archived], scope: stableKey)
        state.ensureCallRecordPersistenceBindingIfNeeded()
        await fulfillment(of: [entered], timeout: 4)
        state.calls = [accepted]
        let lateRollback = state.callStore.makeCallRecordRollback(callID: "accepted")
        var exited = state.apiContext
        exited.clearSession(defaults: defaults, sessionStore: state.protectedSessionStore)
        state.overrideAPIContextForTesting(exited)
        state.ensureCallRecordPersistenceBindingIfNeeded()
        state.bindCallRecordPersistence(for: context)
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
        XCTAssertTrue(state.callStore.calls.isEmpty)

        let persisted = expectation(description: "originally accepted rows reach the legacy reader")
        let reader = CallStore(callRecordStore: archive)
        let expected = [accepted, archived]
        let observation = reader.$calls.dropFirst().filter { $0 == expected }.prefix(1).sink { _ in
            persisted.fulfill()
        }
        defer { observation.cancel() }
        reader.bindCallRecordPersistence(scope: stableKey)
        archive.release()
        await fulfillment(of: [persisted], timeout: 4)
        lateRollback()
        XCTAssertTrue(state.callStore.calls.isEmpty)
        XCTAssertFalse(state.callStore.hasCallRecordPersistenceBinding)
        XCTAssertEqual(archive.writes, [.init(scope: stableKey, records: expected)])
        XCTAssertEqual(archive.records(for: stableKey), expected)
    }

    func callArchiveRefreshResult(_ context: IMAPIContext, token: String) throws -> HTTPTransportResult {
        let tenantID = try XCTUnwrap(context.tenantID)
        let expires = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
            "im_token": token, "expires_at": expires, "tenant_id": tenantID, "auth_session": [
                "session_id": "sess_call_archive_fixture", "refresh_token": "refresh-" + token,
                "expires_at": expires, "tenant_id": tenantID, "app_id": context.appID,
                "device_id": context.deviceID, "client_type": "ios", "token_type": "im",
            ],
        ]])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    private func callHistoryFrame(in window: UIWindow, hostedView: UIView, current: CallRecord, retired: CallRecord) async
        -> (titles: (current: Bool, retired: Bool)?, image: UIImage?, diagnostic: String) {
        window.layoutIfNeeded()
        let currentAX = callHistoryHasRow(id: current.id, in: hostedView)
        let retiredAX = callHistoryHasRow(id: retired.id, in: hostedView)
        let ax = "currentAX=\(currentAX); retiredAX=\(retiredAX)"
        guard hostedView.window === window, !window.isHidden, !window.bounds.isEmpty else {
            return (nil, nil, ax + "; host unavailable")
        }
        var drew = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drew, let data = image.pngData() else {
            return (nil, image, ax + "; window capture unavailable")
        }
        do {
            guard let text = try await Task.detached(operation: { try Self.callHistoryText(in: data) }).value else {
                return (nil, image, ax + "; OCR returned no results")
            }
            let currentPixels = text.contains(current.title.lowercased())
            let retiredPixels = text.contains(retired.title.lowercased())
            return ((current: currentPixels, retired: retiredPixels), image,
                    ax + "; currentPixels=\(currentPixels); retiredPixels=\(retiredPixels); text=\(text)")
        } catch {
            return (nil, image, ax + "; text readback failed: \(error)")
        }
    }

    nonisolated private static func callHistoryText(in image: Data) throws -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: image, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string.lowercased() }
    }

    private func callHistoryHasRow(id: String, in view: UIView) -> Bool {
        let identifier = "rtc_recent_call_\(id)"
        var visited = Set<ObjectIdentifier>()
        func contains(_ element: NSObject) -> Bool {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return false }
            if (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier { return true }
            if let children = element.accessibilityElements, children.compactMap({ $0 as? NSObject }).contains(where: contains) {
                return true
            }
            if let view = element as? UIView, view.subviews.contains(where: { contains($0) }) { return true }
            let count = element.accessibilityElementCount()
            guard count > 0, count != NSNotFound else { return false }
            for index in 0..<count {
                if let child = element.accessibilityElement(at: index) as? NSObject, contains(child) { return true }
            }
            return false
        }
        view.layoutIfNeeded()
        return contains(view)
    }

    func callArchiveTestContext() -> IMAPIContext {
        var context = makeAuthenticatedAPIContext()
        context.tenantID = UUID().uuidString
        context.deviceID = UUID().uuidString
        return context
    }

    func callArchiveTestRecord(_ id: String, title: String? = nil) -> CallRecord {
        CallRecord(id: id, callID: id, title: title ?? id, subtitle: "Fixture", time: "10:00", status: "ended")
    }

    func makeCallArchiveScopeState(
        context: IMAPIContext, archive: FencedCallArchive,
        transport: any HTTPTransport = FakeHTTPTransport(results: []),
        videoMediaClient: any VideoMediaClient = NoopVideoMediaClient(),
        voiceCallSystem: any VoiceCallSystemIntegrating = NoopVoiceCallSystemIntegration()
    ) throws -> (AppState, UserDefaults) {
        let suite = "CallArchiveScopeFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let scopeHash = try LocalMessageScope(context: context).scopeHash
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"),
            scopeRetirementMediaRegistry: IOSMediaCacheStoreRegistry()
        )
        addTeardownBlock {
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            await persistence.waitForScheduledScopePurge(scopeHash: scopeHash)
            guard try !persistence.hasPendingScopeCleanup(context: context) else {
                XCTFail("Private message scope retirement did not finish")
                return
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        }
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [], httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context,
            runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
        )
        let state = AppState(
            api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: videoMediaClient, voiceCallSystem: voiceCallSystem,
            callStore: CallStore(callRecordStore: archive),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence, biometricDefaults: defaults, currentUserIdentityDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context, launchUnitTestOverride: true
        )
        return (state, defaults)
    }
}

final class FencedCallArchive: CallRecordPersisting {
    struct Write: Equatable {
        let scope: String
        let records: [CallRecord]
    }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockedScope: String?
    private let entered: XCTestExpectation
    private var rows: [String: [CallRecord]]
    private var reads: [String] = []
    private var saved: [Write] = []

    init(rows: [String: [CallRecord]], blockedScope: String?, entered: XCTestExpectation) {
        self.rows = rows
        self.blockedScope = blockedScope
        self.entered = entered
    }

    var loadedScopes: [String] { lock.withLock { reads } }
    var writes: [Write] { lock.withLock { saved } }
    func records(for scope: String) -> [CallRecord] { lock.withLock { rows[scope] ?? [] } }
    func seed(_ records: [CallRecord], scope: String) { lock.withLock { rows[scope] = records } }

    func load(scope: String) -> [CallRecord] {
        let shouldBlock = lock.withLock {
            let first = blockedScope.map { $0 == scope && !reads.contains(scope) } ?? reads.isEmpty
            reads.append(scope)
            return first
        }
        if shouldBlock {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 12), .success)
        }
        return records(for: scope)
    }

    func save(_ records: [CallRecord], scope: String) {
        lock.withLock {
            saved.append(Write(scope: scope, records: records))
            rows[scope] = records
        }
    }

    func release() { gate.signal() }
}
// WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
