import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

typealias RTCQualityStatsProvider = @MainActor () async -> [RTCQualityStatRecord]
typealias RTCQualityReporter = @MainActor (_ samples: [RTCQualitySample], _ rtcToken: String) async throws -> Void

@MainActor
final class RTCQualityTelemetrySession {
    static let sampleIntervalNanoseconds: UInt64 = 10_000_000_000
    static let batchSize = 3
    static let maximumPendingSamples = 30
    static let maximumRetryAttempts = 4

    private var rtcToken: String
    private let statsProvider: RTCQualityStatsProvider
    private let reporter: RTCQualityReporter
    private let now: () -> Date
    private var reducer = RTCQualitySampleReducer()
    private var nextSampleSeq: Int64 = 1
    private var routeCollector: RTCTurnRouteCollector
    private let sequenceProvider: (() -> Int64?)?
    private var captureInProgress = false
    private var pending: [RTCQualitySample] = []
    private var timerTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var stopped = false

    init(
        rtcToken: String,
        statsProvider: @escaping RTCQualityStatsProvider,
        reporter: @escaping RTCQualityReporter,
        turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil,
        sequenceProvider: (() -> Int64?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.rtcToken = rtcToken
        self.statsProvider = statsProvider
        self.reporter = reporter
        self.now = now
        self.routeCollector = RTCTurnRouteCollector(capability: turnRouteTelemetry)
        self.sequenceProvider = sequenceProvider
    }

    func start() {
        guard timerTask == nil,
              RTCQualityTokenScope.hasWriteScope(rtcToken) else {
            return
        }
        timerTask = Task { @MainActor [weak self] in
            await self?.captureAndQueue(forceUpload: false, allowStopped: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.sampleIntervalNanoseconds)
                } catch {
                    break
                }
                guard let self, !self.stopped else { break }
                await self.captureAndQueue(forceUpload: false, allowStopped: false)
            }
        }
    }

    func updateRouteCapability(_ capability: RemoteRTCTurnRouteTelemetry?) {
        routeCollector.enableIfPreviouslyUnavailable(capability)
    }

    func updateToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RTCQualityTokenScope.hasWriteScope(normalized) else {
            stopped = true
            timerTask?.cancel()
            timerTask = nil
            pending.removeAll(keepingCapacity: false)
            return
        }
        rtcToken = normalized
    }

    func applicationDidEnterBackground() async {
        await captureAndQueue(forceUpload: true, allowStopped: false)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        timerTask?.cancel()
        timerTask = nil
        await captureAndQueue(forceUpload: true, allowStopped: true)
        scheduleUpload()
    }

    func captureForTesting(forceUpload: Bool) async {
        await captureAndQueue(forceUpload: forceUpload, allowStopped: false)
    }

    var pendingCountForTesting: Int { pending.count }
    var nextSequenceForTesting: Int64 { nextSampleSeq }
    var isStoppedForTesting: Bool { stopped }

    private func captureAndQueue(forceUpload: Bool, allowStopped: Bool) async {
        guard !captureInProgress, allowStopped || !stopped,
              RTCQualityTokenScope.hasWriteScope(rtcToken),
              pending.count < Self.maximumPendingSamples,
              nextSampleSeq <= 10_000 else {
            return
        }
        captureInProgress = true
        defer { captureInProgress = false }
        let records = await statsProvider()
        guard allowStopped || !stopped else { return }
        let observation = routeCollector.observe(records)
        guard let sequence = sequenceProvider?() ?? (sequenceProvider == nil ? nextSampleSeq : nil) else {
            print("[RTCQuality] coverage_gap=sequence_unavailable")
            stopped = true
            timerTask?.cancel()
            timerTask = nil
            scheduleUpload()
            return
        }
        if var sample = reducer.reduce(records: records, sampledAt: now(), sampleSeq: sequence) {
            sample.routeObservation = observation
            pending.append(sample)
        }
        nextSampleSeq = sequence + 1
        if forceUpload || pending.count >= Self.batchSize {
            scheduleUpload()
        }
    }

    private func scheduleUpload() {
        guard uploadTask == nil,
              !pending.isEmpty,
              RTCQualityTokenScope.hasWriteScope(rtcToken) else {
            return
        }
        // Three samples remain comfortably under the existing 64 KiB API
        // limit even with eight transports; drain a backlog in bounded batches.
        let batch = Array(pending.prefix(Self.batchSize))
        let batchSequences = Set(batch.map(\.sampleSeq))
        let token = rtcToken
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reporter(batch, token)
                self.pending.removeAll { batchSequences.contains($0.sampleSeq) }
                self.retryAttempt = 0
                self.uploadTask = nil
                if !self.pending.isEmpty {
                    self.scheduleUpload()
                }
            } catch {
                self.uploadTask = nil
                if let signal = error as? RTCVideoSignalHTTPError,
                   ((signal.statusCode == 400 && signal.code == "bad_json") ||
                    (signal.statusCode == 422 && signal.code == "rtc_quality_route_unsupported")),
                   batch.contains(where: { $0.routeObservation != nil }) {
                    self.routeCollector.disable()
                    // Drop unaccepted extension samples as a coverage gap. Never
                    // strip a queued value and reuse its sequence with new bytes.
                    self.pending.removeAll { $0.routeObservation != nil }
                    self.retryAttempt = 0
                    print("[RTCQuality] coverage_gap=route_unsupported")
                    if !self.pending.isEmpty { self.scheduleUpload() }
                    return
                }
                if let signal = error as? RTCVideoSignalHTTPError,
                   signal.statusCode == 409, signal.code == "rtc_quality_node_mapping_stale" {
                    // Preserve the original bounded batch. Never relabel or resend
                    // its sequence with different content after a directory change.
                    self.stopped = true
                    self.timerTask?.cancel()
                    self.timerTask = nil
                    print("[RTCQuality] coverage_gap=node_mapping_stale")
                    return
                }
                if RTCQualityUploadFailurePolicy.isTerminal(error) {
                    self.pending.removeAll(keepingCapacity: false)
                    self.stopped = true
                    self.timerTask?.cancel()
                    self.timerTask = nil
                    return
                }
                self.retryAttempt += 1
                guard self.retryAttempt <= Self.maximumRetryAttempts else {
                    self.pending.removeAll(keepingCapacity: false)
                    return
                }
                let delay = RTCQualityUploadFailurePolicy.retryDelaySeconds(attempt: self.retryAttempt)
                self.uploadTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.uploadTask = nil
                    self.scheduleUpload()
                }
            }
        }
    }
}
