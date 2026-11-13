import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

final class RTCMediaHeartbeatHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        let result: HTTPTransportResult
        let delayNanoseconds: UInt64
        let ignoresCancellation: Bool

        init(
            result: HTTPTransportResult,
            delayNanoseconds: UInt64 = 0,
            ignoresCancellation: Bool = false
        ) {
            self.result = result
            self.delayNanoseconds = delayNanoseconds
            self.ignoresCancellation = ignoresCancellation
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var capturedRequests: [URLRequest] = []
    private var concurrentRequests = 0
    private(set) var maximumConcurrentRequests = 0

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path == "/api/platform/apps/current-policy" {
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":true,"data":{"app_id":"jianhuitong-ios","phone_auth_enabled":true}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        let path = request.url?.path ?? ""
        if path.hasSuffix("/hangup") || path.hasSuffix("/cancel") {
            lock.withLock { capturedRequests.append(request) }
        }
        guard path.hasSuffix("/media-state") || path.hasSuffix("/join") else {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        let stub: Stub = lock.withLock {
            capturedRequests.append(request)
            concurrentRequests += 1
            maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
            if stubs.isEmpty {
                return Stub(
                    result: HTTPTransportResult(
                        data: Data(#"{"ok":true,"data":{}}"#.utf8),
                        isHTTPResponse: true,
                        statusCode: 200
                    )
                )
            }
            return stubs.removeFirst()
        }
        defer {
            lock.withLock {
                concurrentRequests = max(0, concurrentRequests - 1)
            }
        }
        if stub.delayNanoseconds > 0 {
            if stub.ignoresCancellation {
                try? await Task.sleep(nanoseconds: stub.delayNanoseconds)
            } else {
                try await Task.sleep(nanoseconds: stub.delayNanoseconds)
            }
        }
        return stub.result
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

final class TestVideoMediaClient: VideoMediaClient {
    var isAvailable: Bool { true }
    var cameraAvailable: Bool { true }
    private(set) var stopReasons: [String] = []
    var speakerError: Error?
    var cameraError: Error?
    var switchCameraError: Error?
    var downgradeToAudioError: Error?
    var foregroundError: Error?
    var audioReconcileError: Error?
    private(set) var speakerValues: [Bool] = []
    private(set) var cameraValues: [Bool] = []
    private(set) var switchCameraCount = 0
    private(set) var downgradeToAudioCount = 0
    private(set) var backgroundCount = 0
    private(set) var foregroundCount = 0
    private(set) var audioReconcileCount = 0
    private(set) var startCount = 0
    var firstPrepareDecision: SuspendedBoolDecision?
    private(set) var prepareCount = 0
    private(set) var preparedGeneration: Int?
    private(set) var previewEvents: [String] = []

    func preparePreview(preferFrontCamera: Bool) async throws {
        prepareCount += 1
        let generation = prepareCount
        previewEvents.append("prepare:\(generation)")
        if generation == 1 { _ = await firstPrepareDecision?.wait() }
        preparedGeneration = generation
        previewEvents.append("prepared:\(generation)")
    }

    func start(
        context: VideoMediaSessionContext,
        cameraEnabled: Bool
    ) async throws -> AsyncStream<RTCVideoMediaEvent> {
        startCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {}
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        speakerValues.append(isEnabled)
        if let speakerError { throw speakerError }
    }
    func setCameraEnabled(_ isEnabled: Bool) async throws {
        cameraValues.append(isEnabled)
        if let cameraError { throw cameraError }
    }
    func switchCamera() async throws {
        switchCameraCount += 1
        if let switchCameraError { throw switchCameraError }
    }
    func downgradeToAudio() async throws {
        downgradeToAudioCount += 1
        if let downgradeToAudioError { throw downgradeToAudioError }
    }
    func applicationDidEnterBackground() async {
        backgroundCount += 1
    }
    func applicationWillEnterForeground() async throws {
        foregroundCount += 1
        if let foregroundError { throw foregroundError }
    }
    func reconcileAudioSessionAfterSystemEvent() async throws {
        audioReconcileCount += 1
        if let audioReconcileError { throw audioReconcileError }
    }

    func stop(reason: String) async {
        stopReasons.append(reason)
        preparedGeneration = nil
        previewEvents.append("stop")
    }
}

@MainActor
final class TestVoiceMediaClient: VoiceMediaClient {
    var isAvailable: Bool { true }
    private let events: [RTCVoiceMediaEvent]
    private var startErrors: [Error]
    private(set) var startedContexts: [VoiceMediaSessionContext] = []
    private(set) var speakerValues: [Bool] = []
    private(set) var mutedValues: [Bool] = []
    private(set) var stopReasons: [String] = []
    private(set) var audioReconcileSpeakerValues: [Bool] = []

    init(events: [RTCVoiceMediaEvent] = [], startErrors: [Error] = []) {
        self.events = events
        self.startErrors = startErrors
    }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        startedContexts.append(context)
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        let events = self.events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {
        mutedValues.append(isMuted)
    }

    func setSpeakerEnabled(_ isEnabled: Bool) async {
        speakerValues.append(isEnabled)
    }

    func reconcileAudioSessionAfterSystemEvent(speakerOn: Bool) async throws {
        audioReconcileSpeakerValues.append(speakerOn)
    }

    func stop(reason: String) async {
        stopReasons.append(reason)
    }
}

@MainActor
final class RecordingBiometricAuthenticator: LocalBiometricAuthenticating, @unchecked Sendable {
    private let error: Error?
    private(set) var requestCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws {
        XCTAssertFalse(reason.isEmpty)
        requestCount += 1
        if let error {
            throw error
        }
    }
}

@MainActor
final class SuspendedBiometricAuthenticator: LocalBiometricAuthenticating, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var shouldSucceedNextRequest = false
    private(set) var requestCount = 0

    var isWaiting: Bool { continuation != nil }

    func authenticate(reason: String) async throws {
        XCTAssertFalse(reason.isEmpty)
        requestCount += 1
        if shouldSucceedNextRequest {
            shouldSucceedNextRequest = false
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        if let pending = continuation {
            continuation = nil
            pending.resume()
        } else {
            shouldSucceedNextRequest = true
        }
    }
}
