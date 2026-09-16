import AVFoundation
import Foundation
import Network
import UIKit

struct RTCCallRecordRedialConfirmation: Equatable, Sendable {
    let title: String
    let message: String
    let actionTitle: String

    init(record: RTCCallRecordPayload, viewerIsCaller: Bool, peerName: String) {
        let callTitle = record.callType.title
        let normalizedPeer = peerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalizedPeer.isEmpty ? "对方" : normalizedPeer
        title = "再次拨打\(callTitle)？"
        message = "将向\(target)发起一通新的\(callTitle)。取消不会请求权限或创建呼叫。"
        actionTitle = "拨打\(callTitle)"
    }
}

@MainActor
final class RTCCallRecordRedialCoordinator {
    static let shared = RTCCallRecordRedialCoordinator()

    private(set) var activeKey: String?
    private var networkIsReachable: Bool?
    private let monitor: NWPathMonitor?

    init(monitorsNetwork: Bool = true) {
        if monitorsNetwork {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    self?.networkIsReachable = path.status == .satisfied
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.wenxintong.ios.rtc-record-redial-network"))
        } else {
            monitor = nil
        }
    }

    deinit {
        monitor?.cancel()
    }

    func begin(peerUID: String, callType: RTCCallRecordType) -> Bool {
        let peer = peerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty, activeKey == nil else { return false }
        activeKey = "\(peer)|\(callType.rawValue)"
        return true
    }

    func networkIsAvailable() async -> Bool {
        guard monitor != nil else { return true }
        for _ in 0..<12 {
            if let networkIsReachable { return networkIsReachable }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return monitor?.currentPath.status == .satisfied
    }

    func finish() {
        activeKey = nil
    }

    #if DEBUG
    func debugResetForTesting() {
        activeKey = nil
        networkIsReachable = nil
    }
    #endif
}

final class RTCCallRecordCreateResponseGuard: @unchecked Sendable {
    let excludedHistoricalCallID: String
    let requiredCallType: RTCCallRecordType

    private let lock = NSLock()
    private var consumed = false

    init(excludedHistoricalCallID: String, requiredCallType: RTCCallRecordType) {
        self.excludedHistoricalCallID = excludedHistoricalCallID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requiredCallType = requiredCallType
    }

    func acceptsAndConsumes(_ call: RemoteRTCCall) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return true }
        let created = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let declaredTypes = [call.callType, call.requestedMediaMode, call.mediaMode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !created.isEmpty,
              !excludedHistoricalCallID.isEmpty,
              created != excludedHistoricalCallID,
              !declaredTypes.isEmpty,
              declaredTypes.allSatisfy({ $0 == requiredCallType.rawValue }) else {
            return false
        }
        consumed = true
        return true
    }
}

enum RTCCallRecordRedialFreshnessContext {
    @TaskLocal static var createResponseGuard: RTCCallRecordCreateResponseGuard?

    static var excludedHistoricalCallID: String? {
        createResponseGuard?.excludedHistoricalCallID
    }

    static var requiredCallType: RTCCallRecordType? {
        createResponseGuard?.requiredCallType
    }

    static func withCreateResponseGuard<Result>(
        excluding historicalCallID: String,
        requiredCallType: RTCCallRecordType,
        operation: () throws -> Result
    ) rethrows -> Result {
        try $createResponseGuard.withValue(
            RTCCallRecordCreateResponseGuard(
                excludedHistoricalCallID: historicalCallID,
                requiredCallType: requiredCallType
            ),
            operation: operation
        )
    }

    static func withCreateResponseGuard<Result>(
        excluding historicalCallID: String,
        requiredCallType: RTCCallRecordType,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $createResponseGuard.withValue(
            RTCCallRecordCreateResponseGuard(
                excludedHistoricalCallID: historicalCallID,
                requiredCallType: requiredCallType
            ),
            operation: operation
        )
    }

    static func acceptsCreatedCall(_ call: RemoteRTCCall) -> Bool {
        createResponseGuard?.acceptsAndConsumes(call) ?? true
    }
}

extension AppState {
    func redialRTCCallRecord(
        _ record: RTCCallRecordPayload,
        viewerIsCaller: Bool,
        conversationID: String
    ) {
        let media: RTCCapabilityMedia = record.callType == .audio ? .voice : .video
        guard guardCallLicenseForAction(media) else { return }
        let licenseGeneration = callLicenseActionGeneration(for: media)
        let coordinator = RTCCallRecordRedialCoordinator.shared
        Task { [weak self] in
            guard let self,
                  self.callLicenseActionGeneration(for: media) == licenseGeneration,
                  self.guardCallLicenseForAction(media) else { return }
            await self.performRTCCallRecordRedial(
                record,
                viewerIsCaller: viewerIsCaller,
                conversationID: conversationID,
                coordinator: coordinator,
                licenseGeneration: licenseGeneration
            )
        }
    }

    private func performRTCCallRecordRedial(
        _ record: RTCCallRecordPayload,
        viewerIsCaller: Bool,
        conversationID: String,
        coordinator: RTCCallRecordRedialCoordinator,
        licenseGeneration: UInt64
    ) async {
        let media: RTCCapabilityMedia = record.callType == .audio ? .voice : .video
        let licenseIsCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self,
                  self.callLicenseActionGeneration(for: media) == licenseGeneration else { return false }
            return self.guardCallLicenseForAction(media)
        }
        guard licenseIsCurrent() else { return }
        let liveConversation = conversation(id: conversationID)
        guard liveConversation.kind == .direct,
              let peer = directConversationCallPeer(for: liveConversation) else {
            announceRTCCallRecordRedialFailure(DirectConversationCallPeerResolver.unavailableMessage)
            return
        }
        let expectedPeerUID = record.peerUID(viewerIsCaller: viewerIsCaller)
        let livePeerIdentifiers = Set([peer.id, peer.userID, peer.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard livePeerIdentifiers.contains(expectedPeerUID) else {
            announceRTCCallRecordRedialFailure("会话对象已变化，无法再次呼叫")
            return
        }
        guard coordinator.begin(peerUID: expectedPeerUID, callType: record.callType) else { return }
        defer { coordinator.finish() }
        let networkAvailable = await coordinator.networkIsAvailable()
        guard licenseIsCurrent() else { return }
        guard networkAvailable else {
            announceRTCCallRecordRedialFailure("当前网络不可用，请连接网络后重试")
            return
        }
        guard !isStartingVoiceCall,
              !isStartingVideoCall,
              incomingVoiceCall == nil,
              !callStore.hasTruthfulCall,
              videoCallPreview == nil else {
            announceRTCCallRecordRedialFailure("你当前已有通话，请结束后再试")
            return
        }

        // Permission requests belong to the central call attempt, after its
        // fresh provider/license response. Redial only checks hardware here.
        if let failure = RTCCallRecordDevicePreflight.failureMessage(for: record.callType) {
            announceRTCCallRecordRedialFailure(failure)
            return
        }

        let refreshedConversation = conversation(id: conversationID)
        guard refreshedConversation.kind == .direct,
              let refreshedPeer = directConversationCallPeer(for: refreshedConversation) else {
            announceRTCCallRecordRedialFailure(DirectConversationCallPeerResolver.unavailableMessage)
            return
        }
        let refreshedPeerIdentifiers = Set([refreshedPeer.id, refreshedPeer.userID, refreshedPeer.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard refreshedPeerIdentifiers.contains(expectedPeerUID),
              await coordinator.networkIsAvailable(),
              !isStartingVoiceCall,
              !isStartingVideoCall,
              incomingVoiceCall == nil,
              !callStore.hasTruthfulCall,
              videoCallPreview == nil else {
            announceRTCCallRecordRedialFailure("当前通话条件已变化，请重试")
            return
        }
        guard licenseIsCurrent() else { return }

        switch record.callType {
        case .audio:
            if let reason = voiceCallUnavailableReason(for: refreshedPeer) {
                announceRTCCallRecordRedialFailure(rtcCallRecordRedialMessage(for: reason))
                return
            }
            announceRTCCallRecordRedialStart()
            RTCCallRecordRedialFreshnessContext.withCreateResponseGuard(
                excluding: record.callID,
                requiredCallType: .audio
            ) {
                startOutgoingVoiceCall(to: refreshedPeer, channelID: refreshedConversation.id)
            }
            await waitForRTCCallRecordCreateCompletion(
                callType: .audio,
                expectedPeerUID: expectedPeerUID
            )
        case .video:
            if let reason = videoCallUnavailableReason(for: refreshedPeer) {
                announceRTCCallRecordRedialFailure(rtcCallRecordRedialMessage(for: reason))
                return
            }
            guard rtcCallRecordRedialVideoCameraAvailable else {
                announceRTCCallRecordRedialFailure("未检测到可用摄像头")
                return
            }
            announceRTCCallRecordRedialStart()
            RTCCallRecordRedialFreshnessContext.withCreateResponseGuard(
                excluding: record.callID,
                requiredCallType: .video
            ) {
                startOutgoingVideoCall(
                    to: refreshedPeer,
                    channelID: refreshedConversation.id,
                    cameraEnabled: true
                )
            }
            await waitForRTCCallRecordCreateCompletion(
                callType: .video,
                expectedPeerUID: expectedPeerUID
            )
        }
    }

    private func waitForRTCCallRecordCreateCompletion(
        callType: RTCCallRecordType,
        expectedPeerUID: String
    ) async {
        while true {
            let isStarting = callType == .audio ? isStartingVoiceCall : isStartingVideoCall
            if !isStarting {
                if callType == .video,
                   let call = activeVoiceCall,
                   rtcCallRecordPeerIdentifiers(call.peer).contains(expectedPeerUID),
                   call.connectedAt == nil,
                   call.mediaState != .connected,
                   !call.isRecoveringNetwork,
                   (call.requestedMediaMode != "video" || call.mediaMode != "video" || !call.localCameraEnabled || !strictVideoRedialEnvironmentIsReady) {
                    endActiveVoiceCall()
                    announceRTCCallRecordRedialFailure("视频通话条件已变化，已停止呼叫")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var strictVideoRedialEnvironmentIsReady: Bool {
        rtcCallRecordRedialVideoCameraAvailable
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    private func rtcCallRecordPeerIdentifiers(_ peer: IMUser) -> Set<String> {
        Set([peer.id, peer.userID, peer.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func rtcCallRecordRedialMessage(for reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("添加好友") || normalized.contains("好友关系") {
            return "已不是好友，无法再次呼叫"
        }
        if normalized.contains("注销") || normalized.contains("停用") {
            return "对方账号已停用，无法呼叫"
        }
        if normalized.contains("设备") && normalized.contains("支持视频") {
            return "当前设备不支持视频通话"
        }
        return normalized.isEmpty ? "当前无法再次呼叫" : normalized
    }

    private func announceRTCCallRecordRedialStart() {
        toast = "正在呼叫"
        UIAccessibility.post(notification: .announcement, argument: "正在呼叫")
    }

    private func announceRTCCallRecordRedialFailure(_ message: String) {
        toast = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

@MainActor
private enum RTCCallRecordDevicePreflight {
    static func failureMessage(for callType: RTCCallRecordType) -> String? {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            return "未检测到可用麦克风"
        }
        guard callType == .video else { return nil }
        guard AVCaptureDevice.default(for: .video) != nil else {
            return "未检测到可用摄像头"
        }
        return nil
    }
}
