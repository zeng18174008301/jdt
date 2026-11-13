import IM4Stores
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

// JHT_MOD_BEGIN APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改开始：会话序号计算从 AppState 拆出并避免临时数组分配
typealias ConversationSequenceInspector = IM4Stores.ConversationSequenceInspector
// JHT_MOD_END APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改结束

@MainActor
enum SystemNotificationSound {
    private static let defaultMessageSound = SystemSoundID(1007)
    private static var callPromptPlayer: AVAudioPlayer?
    private static var promptStopTask: Task<Void, Never>?
    private static var activePromptKind: CallPromptKind?
    private static var systemOwnsIncomingRingtone = false
    private static var outgoingRingbackSuppressed = false

    static func playMessage() {
        AudioServicesPlayAlertSound(defaultMessageSound)
    }

    static func startIncomingCallFallback() {
        stopIncomingCallFallback()
        guard !isRunningUnitTests else { return }
        startPlayer(.incomingRingtone, loops: -1)
    }

    static func stopIncomingCallFallback() {
        guard activePromptKind == .incomingRingtone else { return }
        stopPromptPlayer()
    }

    static func render(_ commands: [CallPromptCommand]) {
        for command in commands {
            switch command {
            case .stopAll:
                stopAllCallPrompts()
            case .prepare:
                break
            case .startLoop(let kind):
                startLoop(kind)
            case .playOneShot(let kind, let maximumDuration):
                playOneShot(kind, maximumDuration: maximumDuration)
            case .releasePromptAudioSession:
                // System sounds do not claim the call media audio session.
                break
            }
        }
    }

    static func stopAllCallPrompts() {
        stopPromptPlayer()
    }

    static func setSystemOwnsIncomingRingtone(_ ownsRingtone: Bool) {
        systemOwnsIncomingRingtone = ownsRingtone
        if ownsRingtone {
            stopIncomingCallFallback()
        }
    }

    static func setOutgoingRingbackSuppressed(_ suppressed: Bool) {
        outgoingRingbackSuppressed = suppressed
        if suppressed, activePromptKind == .outgoingRingback {
            stopPromptPlayer()
        }
    }

    private static func startLoop(_ kind: CallPromptKind) {
        guard !isRunningUnitTests else { return }
        switch kind {
        case .incomingRingtone:
            if !systemOwnsIncomingRingtone {
                startIncomingCallFallback()
            }
        case .outgoingRingback:
            guard !outgoingRingbackSuppressed else { return }
            startPlayer(.outgoingRingback, loops: -1)
        case .busy, .connected, .ended:
            playOneShot(kind, maximumDuration: 2.5)
        }
    }

    private static func playOneShot(_ kind: CallPromptKind, maximumDuration: TimeInterval) {
        guard !isRunningUnitTests else { return }
        outgoingRingbackSuppressed = false
        startPlayer(kind, loops: kind == .busy ? 4 : 0)
        let boundedDuration = max(0.05, maximumDuration)
        promptStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(boundedDuration * 1_000_000_000))
            guard !Task.isCancelled, activePromptKind == kind else { return }
            stopPromptPlayer()
        }
    }

    private static func startPlayer(_ kind: CallPromptKind, loops: Int) {
        stopPromptPlayer()
        let player: AVAudioPlayer?
        if let url = bundledToneURL(for: kind) {
            player = try? AVAudioPlayer(contentsOf: url)
        } else if let data = generatedToneData(for: kind) {
            player = try? AVAudioPlayer(data: data)
        } else {
            player = nil
        }
        guard let player else {
            return
        }
        player.numberOfLoops = loops
        player.volume = 0.32
        player.prepareToPlay()
        guard player.play() else { return }
        callPromptPlayer = player
        activePromptKind = kind
    }

    private static func bundledToneURL(for kind: CallPromptKind) -> URL? {
        let resourceName: String
        switch kind {
        case .outgoingRingback:
            resourceName = "rtc_outgoing_ringback"
        case .incomingRingtone:
            resourceName = "rtc_incoming_ringtone"
        case .busy:
            resourceName = "rtc_call_busy"
        case .connected:
            resourceName = "rtc_call_connected"
        case .ended:
            resourceName = "rtc_call_ended"
        }
        for fileExtension in ["caf", "wav", "m4a", "mp3"] {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }

    private static func stopPromptPlayer() {
        promptStopTask?.cancel()
        promptStopTask = nil
        callPromptPlayer?.stop()
        callPromptPlayer = nil
        activePromptKind = nil
    }

    /// Creates short, generic PCM cues at runtime. No bundled or third-party audio asset is used,
    /// and AVAudioPlayer gives every lifecycle transition an immediate stop operation.
    private static func generatedToneData(for kind: CallPromptKind) -> Data? {
        let segments: [(frequency: Double, duration: Double)]
        switch kind {
        case .outgoingRingback:
            segments = [(440, 0.28), (0, 0.82)]
        case .incomingRingtone:
            segments = [(660, 0.34), (0, 0.16), (660, 0.34), (0, 1.36)]
        case .busy:
            segments = [(480, 0.24), (0, 0.24)]
        case .connected:
            segments = [(880, 0.13)]
        case .ended:
            segments = [(440, 0.14), (330, 0.22)]
        }
        let sampleRate: UInt32 = 22_050
        let fadeSamples = max(1, Int(Double(sampleRate) * 0.006))
        var samples: [Int16] = []
        for segment in segments {
            let count = max(1, Int(segment.duration * Double(sampleRate)))
            for index in 0..<count {
                guard segment.frequency > 0 else {
                    samples.append(0)
                    continue
                }
                let leading = min(1, Double(index) / Double(fadeSamples))
                let trailing = min(1, Double(count - index - 1) / Double(fadeSamples))
                let envelope = max(0, min(leading, trailing))
                let angle = 2 * Double.pi * segment.frequency * Double(index) / Double(sampleRate)
                samples.append(Int16(sin(angle) * Double(Int16.max) * 0.22 * envelope))
            }
        }
        guard !samples.isEmpty else { return nil }
        let pcmByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36) + pcmByteCount, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(pcmByteCount, to: &data)
        for sample in samples {
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
