import IM4Domain
import Combine
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

// WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_BEGIN
@MainActor
final class VoiceMessagePlaybackStore {
    struct Snapshot: Equatable {
        let isPlaying: Bool
        let state: VoiceMessagePlaybackState?
    }

    @Published var playingMessageID: String?
    @Published var state: VoiceMessagePlaybackState?

    func snapshot(for messageID: String) -> Snapshot {
        Snapshot(isPlaying: playingMessageID == messageID, state: state?.messageID == messageID ? state : nil)
    }

    func updates(for messageID: String) -> AnyPublisher<Snapshot, Never> {
        $playingMessageID.combineLatest($state)
            .map { playingID, state in
                Snapshot(isPlaying: playingID == messageID, state: state?.messageID == messageID ? state : nil)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
// WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_END

extension AppState {
    func toggleVoiceMessagePlayback(_ message: ChatMessage, conversationID: String) {
        guard message.kind == .voice else { return }
        if voiceMessagePlayerMessageID == message.id, let player = voiceMessagePlayer {
            guard let durationMS = voicePlayerDurationMS(player) else {
                clearVoiceMessagePlayback()
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音播放失败，请重试")
                return
            }
            if player.isPlaying {
                player.pause()
                voiceMessagePlaybackStore.playingMessageID = nil
                voiceMessagePlaybackTimer?.invalidate()
                voiceMessagePlaybackTimer = nil
                updateVoiceMessagePlaybackState(
                    messageID: message.id,
                    elapsedMS: Int((player.currentTime * 1_000).rounded()),
                    durationMS: durationMS,
                    isPlaying: false
                )
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } else {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard player.play() else {
                        throw IMAPIError.server("语音播放启动失败")
                    }
                    voiceMessagePlaybackStore.playingMessageID = message.id
                    updateVoiceMessagePlaybackState(
                        messageID: message.id,
                        elapsedMS: Int((player.currentTime * 1_000).rounded()),
                        durationMS: durationMS,
                        isPlaying: true
                    )
                    startVoiceMessagePlaybackProgressTimer(
                        messageID: message.id,
                        generation: voiceMessagePlaybackGeneration
                    )
                } catch {
                    clearVoiceMessagePlayback()
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音播放失败，请重试")
                }
            }
            return
        }
        if voiceMessagePlayerMessageID == message.id {
            stopVoiceMessagePlayback()
            return
        }
        stopVoiceMessagePlayback()
        let requestID = message.id
        voiceMessagePlaybackGeneration &+= 1
        let generation = voiceMessagePlaybackGeneration
        voiceMessagePlayerMessageID = requestID
        voiceMessagePlaybackStore.playingMessageID = nil
        updateVoiceMessagePlaybackState(
            messageID: requestID,
            elapsedMS: 0,
            durationMS: estimatedVoiceMessageDurationMS(message),
            isPlaying: false
        )
        Task { [weak self] in
            do {
                guard let self else { return }
                let localURL = try await self.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                guard self.voiceMessagePlayerMessageID == requestID,
                      self.voiceMessagePlaybackGeneration == generation else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(contentsOf: localURL)
                guard player.prepareToPlay(),
                      let durationMS = self.voicePlayerDurationMS(player) else {
                    throw IMAPIError.server("语音解码失败")
                }
                let delegate = VoiceMessageAudioPlayerDelegate()
                delegate.didFinish = { [weak self] finishedPlayerID, succeeded in
                    guard let self,
                          self.voiceMessagePlaybackGeneration == generation,
                          let activePlayer = self.voiceMessagePlayer,
                          ObjectIdentifier(activePlayer) == finishedPlayerID,
                          let actualDurationMS = self.voicePlayerDurationMS(activePlayer) else {
                        return
                    }
                    self.updateVoiceMessagePlaybackState(
                        messageID: requestID,
                        elapsedMS: actualDurationMS,
                        durationMS: actualDurationMS,
                        isPlaying: false
                    )
                    self.clearVoiceMessagePlayback(
                        expectedGeneration: generation,
                        preservePlaybackState: succeeded
                    )
                    if !succeeded {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("语音播放失败，请重试")
                    }
                }
                delegate.didFailToDecode = { [weak self] failedPlayerID in
                    guard let self,
                          self.voiceMessagePlaybackGeneration == generation,
                          let activePlayer = self.voiceMessagePlayer,
                          ObjectIdentifier(activePlayer) == failedPlayerID else {
                        return
                    }
                    self.clearVoiceMessagePlayback(expectedGeneration: generation)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("语音播放失败，请重试")
                }
                player.delegate = delegate
                self.voiceMessagePlayerDelegate = delegate
                self.voiceMessagePlayer = player
                guard player.play() else {
                    throw IMAPIError.server("语音播放启动失败")
                }
                self.voiceMessagePlaybackStore.playingMessageID = requestID
                self.updateVoiceMessagePlaybackState(
                    messageID: requestID,
                    elapsedMS: 0,
                    durationMS: durationMS,
                    isPlaying: true
                )
                self.startVoiceMessagePlaybackProgressTimer(messageID: requestID, generation: generation)
            } catch is CancellationError {
                if self?.voiceMessagePlayerMessageID == requestID,
                   self?.voiceMessagePlaybackGeneration == generation {
                    self?.clearVoiceMessagePlayback(expectedGeneration: generation)
                }
            } catch {
                if self?.voiceMessagePlayerMessageID == requestID,
                   self?.voiceMessagePlaybackGeneration == generation {
                    self?.clearVoiceMessagePlayback(expectedGeneration: generation)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self?.setToast("语音播放失败，请重试")
                }
            }
        }
    }

    func stopVoiceMessagePlayback(ifPlaying messageID: String? = nil) {
        if let messageID, voiceMessagePlayerMessageID != messageID { return }
        stopVoiceMessagePlayback()
    }

    func stopVoiceMessagePlayback() {
        clearVoiceMessagePlayback()
    }

    private func clearVoiceMessagePlayback(
        expectedGeneration: UInt64? = nil,
        preservePlaybackState: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.clearVoiceMessagePlayback(
                    expectedGeneration: expectedGeneration,
                    preservePlaybackState: preservePlaybackState
                )
            }
            return
        }
        if let expectedGeneration,
           voiceMessagePlaybackGeneration != expectedGeneration {
            return
        }
        voiceMessagePlaybackGeneration &+= 1
        voiceMessagePlaybackTimer?.invalidate()
        voiceMessagePlaybackTimer = nil
        voiceMessagePlayer?.stop()
        voiceMessagePlayer = nil
        voiceMessagePlayerDelegate = nil
        voiceMessagePlayerMessageID = nil
        voiceMessagePlaybackStore.playingMessageID = nil
        if !preservePlaybackState {
            voiceMessagePlaybackStore.state = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startVoiceMessagePlaybackProgressTimer(messageID: String, generation: UInt64) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startVoiceMessagePlaybackProgressTimer(messageID: messageID, generation: generation)
            }
            return
        }
        voiceMessagePlaybackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVoiceMessagePlaybackProgress(messageID: messageID, generation: generation)
            }
        }
        voiceMessagePlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshVoiceMessagePlaybackProgress(messageID: String, generation: UInt64) {
        guard voiceMessagePlaybackGeneration == generation,
              voiceMessagePlayerMessageID == messageID,
              let player = voiceMessagePlayer else {
            clearVoiceMessagePlayback(expectedGeneration: generation)
            return
        }
        guard let durationMS = voicePlayerDurationMS(player) else {
            clearVoiceMessagePlayback(expectedGeneration: generation)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音播放失败，请重试")
            return
        }
        let elapsedMS = min(durationMS, max(0, Int((player.currentTime * 1_000).rounded())))
        updateVoiceMessagePlaybackState(
            messageID: messageID,
            elapsedMS: elapsedMS,
            durationMS: durationMS,
            isPlaying: player.isPlaying
        )
        guard !player.isPlaying else { return }
        voiceMessagePlaybackTimer?.invalidate()
        voiceMessagePlaybackTimer = nil
        if elapsedMS >= durationMS {
            clearVoiceMessagePlayback(expectedGeneration: generation, preservePlaybackState: true)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func updateVoiceMessagePlaybackState(
        messageID: String,
        elapsedMS: Int,
        durationMS: Int,
        isPlaying: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateVoiceMessagePlaybackState(
                    messageID: messageID,
                    elapsedMS: elapsedMS,
                    durationMS: durationMS,
                    isPlaying: isPlaying
                )
            }
            return
        }
        voiceMessagePlaybackStore.state = VoiceMessagePlaybackState(
            messageID: messageID,
            elapsedMS: elapsedMS,
            durationMS: max(1, VoiceMessagePayload.normalizedDurationMS(durationMS)),
            isPlaying: isPlaying
        )
    }

    private func estimatedVoiceMessageDurationMS(_ message: ChatMessage) -> Int {
        if let seconds = message.attachmentDurationSeconds, seconds > 0 {
            return VoiceMessagePayload.decodedDurationMS(seconds) ?? VoiceMessagePayload.minDurationMS // WDT_IOS1_SAFE_NUMERIC_20261023
        }
        return VoiceMessagePayload.minDurationMS
    }

    private func voicePlayerDurationMS(_ player: AVAudioPlayer) -> Int? {
        VoiceMessagePayload.decodedDurationMS(player.duration)
    }

    func prepareMessageAttachmentLocalFile(_ message: ChatMessage, conversationID: String, preferPreview: Bool = false, forChatThumbnail: Bool = false,
        prefetchedDetail: RemoteUserFileDetail? = nil) async throws -> URL { // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: a cell may still hold the snapshot from before file-detail refresh.
        let message = currentAttachmentCacheMessage(message, conversationID: conversationID)
        let scope = contentCacheScopeKey
        let attachmentID = attachmentProgressKey(for: message, preferPreview: preferPreview)
        let localURL = try await withSharedAttachmentDownload(attachmentID: attachmentID, showsProgress: !forChatThumbnail) { token in
            try await self.downloadMessageAttachmentLocalFile(message, conversationID: conversationID,
                preferPreview: preferPreview, attachmentID: attachmentID, token: token, forChatThumbnail: forChatThumbnail,
                prefetchedDetail: prefetchedDetail) // WDT_IOS1_CHAT_IMAGE_THUMBNAIL_20261113
        }
        try Task.checkCancellation()
        guard contentCacheScopeKey == scope else { throw CancellationError() }
        // WDT_APP_CONTRACT_20261021_10: cache hits and joined file-page tasks also update chat presentation.
        if !forChatThumbnail, cachedLocalAttachmentURL(for: message, preferPreview: preferPreview) == nil {
            let category = attachmentMediaCategory(for: message)
            let resources = await AttachmentPreviewResourceBuilder.downloadedPreviewResourcesOffMain(
                messageID: message.id, localURL: localURL, mediaCategory: category)
            try Task.checkCancellation()
            guard contentCacheScopeKey == scope else { throw CancellationError() }
            if let resources {
                let fileExtension = attachmentFileExtension(for: message, remoteURL: nil, mediaCategory: category)
                cacheLocalAttachmentResources(resources, messageID: message.id, fileID: message.attachmentFileID,
                    cacheIdentity: attachmentStableCacheIdentity(for: message, mediaCategory: category, fallbackExtension: fileExtension))
            }
        }
        return localURL
    }

}
