import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

public enum VoiceRecordingAppActivity: Equatable {
    case active
    case inactive
    case background

    public init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}

public enum VoiceRecordingComposerPhase: Equatable {
    case idle
    case requesting
    case recording
    case finalizing
    case preview
}

public enum VoiceRecordingComposerFeedback: Equatable {
    case tooShort

    public var message: String {
        switch self {
        case .tooShort:
            return "说话时间太短"
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .tooShort:
            return "chat_voice_recording_feedback_too_short"
        }
    }
}

public enum VoiceRecordingComposerLifecycleEffect: Equatable {
    case none
    case cancelAndReset
}

public struct VoiceRecordingComposerLifecycle: Equatable {
    private(set) public var feedback: VoiceRecordingComposerFeedback?

    mutating public func presentTooShortFeedback() {
        feedback = .tooShort
    }

    mutating public func beginNewAttempt() {
        feedback = nil
    }

    mutating public func clearFeedback() {
        feedback = nil
    }

    mutating public func transition(
        to appActivity: VoiceRecordingAppActivity,
        recordingPhase: VoiceRecordingComposerPhase
    ) -> VoiceRecordingComposerLifecycleEffect {
        guard appActivity != .active else { return .none }
        feedback = nil
        if appActivity == .inactive, recordingPhase == .requesting {
            // The system microphone permission sheet temporarily makes the app
            // inactive. Keep that user-triggered request alive unless the app
            // actually reaches the background.
            return .none
        }
        return recordingPhase == .idle ? .none : .cancelAndReset
    }
}

public struct VoiceMessageRecording {
    public let data: Data
    public let name: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let durationMS: Int
    public let waveform: [Int]

    func replacingDurationMS(_ durationMS: Int) -> VoiceMessageRecording {
        VoiceMessageRecording(
            data: data,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            durationMS: VoiceMessagePayload.normalizedDurationMS(durationMS),
            waveform: waveform
        )
    }

    public init(data: Data,
        name: String,
        mimeType: String,
        sizeBytes: Int64,
        durationMS: Int,
        waveform: [Int]) {
        self.data = data
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.durationMS = durationMS
        self.waveform = waveform
    }
}

public enum VoiceMessageRecorderError: LocalizedError {
    case tooShort
    case emptyData
    case invalidDuration
    case failedToStart

    public var errorDescription: String? {
        switch self {
        case .tooShort:
            return "说话时间太短"
        case .emptyData:
            return "语音数据读取失败，请重新录制"
        case .invalidDuration:
            return "语音时长无法读取，请重新录制"
        case .failedToStart:
            return "录音启动失败，请重试"
        }
    }
}

