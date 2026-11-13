import Combine
import Foundation
import XCTest
import MachO
import IM4Domain
@testable import IM4Stores
@testable import WenDaTong

// WDT_IOS1_CALLS_INDEPENDENT_ACCEPTANCE_DIAGNOSIS_20261111
@MainActor
func recordCallsAcceptanceDiagnostic(_ test: XCTestCase, state: AppState, stage: String, counts: [String: Int]) {
    let row: [String: Any] = [
        "stage": stage,
        "authenticated": state.isAuthenticated,
        "hasIMSession": state.apiContext.hasIMSession,
        "voiceAvailable": state.voiceMediaClient.isAvailable,
        "voiceAvailableOverride": String(describing: state.voiceMediaClientAvailableOverride),
        "videoAvailable": state.videoMediaClient.isAvailable,
        "voiceLicenseKnown": state.fileUploadConfig.voiceCallLicenseKnown,
        "voiceLicenseEnabled": state.fileUploadConfig.voiceCallEnabled,
        "videoLicenseKnown": state.fileUploadConfig.videoCallLicenseKnown,
        "videoLicenseEnabled": state.fileUploadConfig.videoCallEnabled,
        "hasVoiceAttempt": state.currentDirectCallAttempt(for: .voice) != nil,
        "hasVideoAttempt": state.currentDirectCallAttempt(for: .video) != nil,
        "answerMode": String(describing: state.incomingCallAnswerMode),
        "toast": String(describing: state.toast),
        "capabilityAlert": String(describing: state.rtcCapabilityAlertMessage),
        "ending": state.isEndingActiveCall,
        "endError": String(describing: state.activeCallEndError),
        "requests": counts
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    let attachment = XCTAttachment(string: text)
    attachment.name = "calls-acceptance-" + stage
    attachment.lifetime = .keepAlways
    test.add(attachment)
}

// Keep preparation and the later service-failure operation separately observable.
// Both phases use the existing fake transport; no request history is reset or hidden.
final class CallsAcceptancePhasedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let preparation: VideoCallStartHTTPTransport
    private let operation: VideoCallStartHTTPTransport
    private var operationStarted = false

    init(preparation: VideoCallStartHTTPTransport, operation: VideoCallStartHTTPTransport) {
        self.preparation = preparation
        self.operation = operation
    }

    func beginOperation() {
        lock.withLock { operationStarted = true }
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let transport = lock.withLock { operationStarted ? operation : preparation }
        return try await transport.data(for: request)
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        let transport = lock.withLock { operationStarted ? operation : preparation }
        return try await transport.upload(for: request, from: data, delegate: delegate)
    }
}

// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
final class StoresContactBoundaryTests: XCTestCase {
    @MainActor
    func testAppAliasesUseSingleRealStoresAndDomainTypesWithOriginalDefaults() {
        XCTAssertEqual(ObjectIdentifier(WenDaTong.ContactStore.self), ObjectIdentifier(IM4Stores.ContactStore.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.GroupSelfProfileStore.self), ObjectIdentifier(IM4Stores.GroupSelfProfileStore.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.ProfileContactRevisionFence.self), ObjectIdentifier(IM4Stores.ProfileContactRevisionFence.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.InboxItem.self), ObjectIdentifier(IM4Domain.InboxItem.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.DeviceSession.self), ObjectIdentifier(IM4Domain.DeviceSession.self))
        XCTAssertEqual(String(reflecting: WenDaTong.ContactStore.self), "IM4Stores.ContactStore")
        let item = WenDaTong.InboxItem(id: "notice", title: "Title", subtitle: "Body", time: "10:00",
            category: " announcement ", isRead: false, accentHex: 42)
        XCTAssertEqual(item.avatarURL, ""); XCTAssertNil(item.groupInviteApproval); XCTAssertEqual(item.sortTimestamp, 0)
        XCTAssertTrue(item.isAnnouncement); XCTAssertEqual(item.normalizedCategory, "公告")
        var device = WenDaTong.DeviceSession(id: "device", name: "Phone", platform: "iOS", lastSeen: "now",
            status: "trusted", isBound: true, isBlocked: false)
        let unchanged = device
        XCTAssertEqual(Set([device, unchanged]).count, 1)
        device.isBlocked = true
        XCTAssertNotEqual(device, unchanged)
    }

    @MainActor
    func testMovedStorePreservesSynchronousPublishedReentryAndGroupSelfReset() {
        let store = IM4Stores.ContactStore()
        var snapshots: [IM4Stores.ContactStore.DirectoryPresentationSnapshot] = []
        var reentered = false, backingWasOldAtPublication = false
        let directory = store.directoryPresentationUpdates.sink { snapshot in
            snapshots.append(snapshot)
            if snapshot.contacts.first?.id == "peer", !reentered {
                reentered = true
                backingWasOldAtPublication = store.contacts.isEmpty
                store.remarks["peer"] = "from-original-sync-callback"
            }
        }
        defer { directory.cancel() }
        let peer = IM4Domain.IMUser(id: "peer", userID: "public-number", username: "peer-name", name: "Peer",
            title: "", department: "", phone: "", email: "", status: "online", enterprise: "", avatarSeed: 0, badges: [])
        store.contacts = [peer]
        XCTAssertTrue(reentered); XCTAssertTrue(backingWasOldAtPublication, "original @Published willSet timing changed")
        // Original CombineLatest drops its nested emission while delivering this callback (baseline unit count2).
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.contacts, [peer])
        XCTAssertEqual(snapshots.last?.remarks, [:])
        XCTAssertEqual(store.remarks, ["peer": "from-original-sync-callback"])
        var fresh: IM4Stores.ContactStore.DirectoryPresentationSnapshot?
        let late = store.directoryPresentationUpdates.first().sink { fresh = $0 }
        defer { late.cancel() }
        XCTAssertEqual(fresh?.contacts, [peer]); XCTAssertEqual(fresh?.remarks, store.remarks)
        XCTAssertEqual(store.contacts, [peer])
        var nicknames: [String] = []
        let profiles = store.groupSelfProfiles.updates(for: "scope|group", \.nickname).sink { nicknames.append($0) }
        defer { profiles.cancel() }
        store.groupSelfProfiles.set(nickname: "Self", member: peer, for: "scope|group")
        store.groupSelfProfiles.set(nickname: "Self", member: peer, for: "scope|group")
        XCTAssertEqual(nicknames, ["", "Self"])
        store.reset()
        XCTAssertEqual(nicknames, ["", "Self", ""])
        XCTAssertTrue(store.contacts.isEmpty); XCTAssertTrue(store.remarks.isEmpty)
        XCTAssertNil(store.groupSelfProfiles.snapshot(for: "scope|group").member)
    }
}
// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END

// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
extension DomainStoreTests {
    func testPhysicalCallsFamilyUsesOneRealStoreAndOriginalSynchronousPublication() {
        // Retain actual native loaded images, independent of DerivedData path assumptions.
        var nativeImages = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return ["WenDaTong", "WenDaTong.debug.dylib", "WenDaTongTests"].contains(URL(fileURLWithPath: path).lastPathComponent) ? path : nil
        }
        if let executable = Bundle.main.executableURL { nativeImages.append(executable.path) }
        nativeImages = Array(Set(nativeImages)).sorted()
        let loaded = XCTAttachment(string: nativeImages.joined(separator: "\n"))
        loaded.name = "physical-chain-native-loaded-paths"; loaded.lifetime = .keepAlways; add(loaded)
        for path in nativeImages {
            let original = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
            original.name = "physical-chain-native-loaded-" + URL(fileURLWithPath: path).lastPathComponent
            original.lifetime = .keepAlways; add(original)
        }
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store: IM4Stores.CallStore = state.callStore
        XCTAssertEqual(ObjectIdentifier(WenDaTong.CallStore.self), ObjectIdentifier(IM4Stores.CallStore.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.VoiceCallSession.self), ObjectIdentifier(IM4Stores.VoiceCallSession.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.RTCVideoConnectionGate.self), ObjectIdentifier(IM4Stores.RTCVideoConnectionGate.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.CallLifecycleStateMachine.self), ObjectIdentifier(IM4Stores.CallLifecycleStateMachine.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.CallPromptCoordinator.self), ObjectIdentifier(IM4Stores.CallPromptCoordinator.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.CallRecord.self), ObjectIdentifier(IM4Domain.CallRecord.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.RTCVoiceMediaState.self), ObjectIdentifier(IM4Domain.RTCVoiceMediaState.self))
        XCTAssertEqual(String(reflecting: type(of: store)), "IM4Stores.CallStore")
        var oldBackingWasVisible = false, appNotifications = 0, incomingIDs: [String] = []
        let global = state.objectWillChange.sink { appNotifications += 1 }
        let local = store.$incomingVoiceCall.dropFirst().sink { value in
            guard let value else { return }
            incomingIDs.append(value.id)
            oldBackingWasVisible = store.incomingVoiceCall == nil
            store.isStartingVoiceCall = true
        }
        defer { local.cancel(); global.cancel(); store.reset() }
        store.incomingVoiceCall = IncomingVoiceCall(id: "physical-incoming", caller: makeUser(id: "physical-peer", name: "Peer"), startedAt: "now", source: "好友语音通话")
        XCTAssertTrue(oldBackingWasVisible)
        XCTAssertEqual(incomingIDs, ["physical-incoming"])
        XCTAssertTrue(state.callStore.isStartingVoiceCall)
        XCTAssertEqual(state.callStore.incomingVoiceCall?.id, "physical-incoming")
        XCTAssertEqual(appNotifications, 0)
        XCTAssertTrue(store === state.callStore)
    }
}

// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
extension DomainStoreTests {
    func testPhysicalFileStoreKeepsOriginalInstanceAndSynchronousPublishedTimingWithoutGlobalForwarding() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store: IM4Stores.FileStore = state.fileStore
        XCTAssertEqual(ObjectIdentifier(WenDaTong.FileStore.self), ObjectIdentifier(IM4Stores.FileStore.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.FileItem.self), ObjectIdentifier(IM4Domain.FileItem.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.PendingAttachmentUpload.self), ObjectIdentifier(IM4Domain.PendingAttachmentUpload.self))
        XCTAssertEqual(ObjectIdentifier(WenDaTong.LocalAttachmentPreviewResources.self), ObjectIdentifier(IM4Domain.LocalAttachmentPreviewResources.self))
        XCTAssertEqual(String(reflecting: type(of: store)), "IM4Stores.FileStore")
        var globalNotifications = 0, observedOldBacking = false, emitted: [Int] = []
        let global = state.objectWillChange.sink { globalNotifications += 1 }
        let local = store.$mediaNetworkRecoveryGeneration.dropFirst().sink { value in
            emitted.append(value)
            observedOldBacking = store.mediaNetworkRecoveryGeneration == 0
            store.markAttachmentDownloadFailed(attachmentID: "same-sync-callback")
        }
        defer { global.cancel(); local.cancel(); store.reset() }
        store.noteMediaNetworkRecovery()
        XCTAssertTrue(observedOldBacking, "Original Published willSet timing must remain synchronous")
        XCTAssertEqual(emitted, [1])
        XCTAssertEqual(state.fileStore.mediaNetworkRecoveryGeneration, 1)
        XCTAssertTrue(state.fileStore.isAttachmentDownloadFailed(attachmentID: "same-sync-callback"))
        XCTAssertEqual(globalNotifications, 0)
        XCTAssertTrue(store === state.fileStore)
    }
}

// Independent acceptance fixture only: recorded provider preparation then the original operation transport.
final class CallsAcceptancePhasedHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let preparation: FakeHTTPTransport
    private let operation: any HTTPTransport
    private var operationStarted = false
    init(preparation: FakeHTTPTransport, operation: any HTTPTransport) {
        self.preparation = preparation; self.operation = operation
    }
    func beginOperation() { lock.withLock { operationStarted = true } }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let target: any HTTPTransport = lock.withLock { operationStarted ? operation : preparation }
        return try await target.data(for: request).resolvingResponseURL(request.url)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let target: any HTTPTransport = lock.withLock { operationStarted ? operation : preparation }
        return try await target.upload(for: request, from: data, delegate: delegate).resolvingResponseURL(request.url)
    }
    static func providerPreparation() -> FakeHTTPTransport {
        FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"call_types":["audio","video"],"voice_call_enabled":true,"video_call_enabled":true,"video_supported":true,"capabilities_version":"video-call-v1","media_plane_configured":true,"ice_servers_configured":true}}"#.utf8),
            isHTTPResponse: true, statusCode: 200)])
    }
}
