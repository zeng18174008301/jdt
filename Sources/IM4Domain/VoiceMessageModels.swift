import Foundation

public enum VoiceMicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

public enum VoiceMessagePermissionGate {
    static public func shouldRequestMicrophone(
        userTriggered: Bool,
        businessBlocked: Bool,
        status: VoiceMicrophoneAuthorizationStatus
    ) -> Bool {
        userTriggered && !businessBlocked && status == .notDetermined
    }
}

public enum VoiceMessagePayload {
    static public let minDurationMS = 1_000
    static public let maxDurationMS = 60_000
    static let maxWaveformSamples = 64
    static public let fallbackText = "[语音]"

    static public func isTooShort(durationMS: Int) -> Bool {
        durationMS < minDurationMS
    }

    static public func normalizedDurationMS(_ durationMS: Int) -> Int {
        min(max(durationMS, 0), maxDurationMS)
    }

    static func isValidFinalDurationMS(_ durationMS: Int) -> Bool {
        (1...maxDurationMS).contains(durationMS)
    }

    static public func isSendableDurationMS(_ durationMS: Int) -> Bool {
        (minDurationMS...maxDurationMS).contains(durationMS)
    }

    static public func decodedDurationMS(_ decodedDurationSeconds: TimeInterval?) -> Int? {
        guard let decodedDurationSeconds,
              decodedDurationSeconds.isFinite,
              decodedDurationSeconds > 0 else {
            return nil
        }
        let durationMilliseconds = decodedDurationSeconds * 1_000.0
        guard durationMilliseconds <= Double(maxDurationMS) + 0.499 else {
            return nil
        }
        let durationMS = Int(durationMilliseconds.rounded())
        guard isValidFinalDurationMS(durationMS) else { return nil }
        return durationMS
    }

    static func authoritativeDurationMS(
        metadataDurationMS _: Int,
        decodedDurationSeconds: TimeInterval?
    ) -> Int? {
        decodedDurationMS(decodedDurationSeconds)
    }

    static public func durationSeconds(from durationMS: Int) -> Int {
        let clamped = normalizedDurationMS(durationMS)
        guard clamped > 0 else { return 0 }
        return max(1, Int(ceil(Double(clamped) / 1_000.0)))
    }

    static public func durationLabel(durationMS: Int?) -> String {
        guard let durationMS, durationMS > 0 else { return "" }
        return "\(durationSeconds(from: durationMS))秒"
    }

    static func playbackProgress(elapsedMS: Int, durationMS: Int) -> Double {
        let duration = normalizedDurationMS(durationMS)
        guard duration > 0 else { return 0 }
        return min(max(Double(max(0, elapsedMS)) / Double(duration), 0), 1)
    }

    static func remainingDurationMS(elapsedMS: Int, durationMS: Int) -> Int {
        max(0, normalizedDurationMS(durationMS) - max(0, elapsedMS))
    }

    static func countdownLabel(elapsedMS: Int, durationMS: Int) -> String {
        let remaining = remainingDurationMS(elapsedMS: elapsedMS, durationMS: durationMS)
        return durationLabel(durationMS: remaining)
    }

    static public func normalizedWaveform(_ samples: [Int]) -> [Int] {
        let clamped = samples.map { min(max($0, 0), 100) }
        guard !clamped.isEmpty else {
            return Array(repeating: 12, count: 12)
        }
        guard clamped.count > maxWaveformSamples else {
            return clamped
        }
        return (0..<maxWaveformSamples).map { index in
            let start = index * clamped.count / maxWaveformSamples
            let end = max(start + 1, (index + 1) * clamped.count / maxWaveformSamples)
            let slice = clamped[start..<min(end, clamped.count)]
            guard !slice.isEmpty else { return clamped[min(start, clamped.count - 1)] }
            return Int(round(Double(slice.reduce(0, +)) / Double(slice.count)))
        }
    }
}

public struct VoiceMessagePlaybackState: Equatable, Sendable {
    public let messageID: String
    public let elapsedMS: Int
    public let durationMS: Int
    public let isPlaying: Bool

    public init(messageID: String, elapsedMS: Int, durationMS: Int, isPlaying: Bool = false) {
        let boundedDurationMS = max(1, VoiceMessagePayload.normalizedDurationMS(durationMS))
        let boundedElapsedMS = min(boundedDurationMS, max(0, elapsedMS))
        self.messageID = messageID
        self.elapsedMS = boundedElapsedMS
        self.durationMS = boundedDurationMS
        self.isPlaying = isPlaying && boundedElapsedMS < boundedDurationMS
    }

    public var progress: Double {
        VoiceMessagePayload.playbackProgress(elapsedMS: elapsedMS, durationMS: durationMS)
    }

    public var remainingMS: Int {
        VoiceMessagePayload.remainingDurationMS(elapsedMS: elapsedMS, durationMS: durationMS)
    }

    public var remainingLabel: String {
        VoiceMessagePayload.countdownLabel(elapsedMS: elapsedMS, durationMS: durationMS)
    }
}
