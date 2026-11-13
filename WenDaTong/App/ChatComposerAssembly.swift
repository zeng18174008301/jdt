import IM4Features
import IM4Domain
import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN
struct ChatComposer: View {
    @StateObject var presentation = ChatComposerPresentationState()
    let conversationID: String
    @Binding var input: String
    @Binding var replyQuote: String?
    @Binding var replyContext: MessageReplyContext?
    @Binding var showTools: Bool
    @Binding var showEmoji: Bool
    @Binding var mentionAllSelected: Bool
    var mentionGroupID = ""
    var mentionMembers: [IMUser] = []
    var mentionMembersLoading = false
    var canMentionAll = false
    var isDisabled = false
    var showsDisabledNotice = true
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    var disabledTitle: String? = nil
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END
    var disabledReason = ""
    var friendActionTitle: String?
    var isApplyingFriend = false
    var allowsVoiceCall = true
    var allowsVideoCall = false
    var voiceCallAccessibilityHint = ""
    var videoCallAccessibilityHint = ""
    var startVoiceCall: () -> Void = {}
    var startVideoCall: () -> Void = {}
    var applyFriend: () -> Void = {}
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_COMPOSER_PARAM - 修改开始：ChatComposer 接收输入框聚焦回调
    var onBeginEditing: () -> Void = {}
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_COMPOSER_PARAM - 修改结束：ChatComposer 接收输入框聚焦回调
    // WDT_CHAT_KEYBOARD_INSET_20261021
    var onEditingChanged: (Bool) -> Void = { _ in }
    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_PARAM - 修改开始：Composer 操作触发滚动到最新消息回调
    var onRequestLatestScroll: () -> Void = {}
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_PARAM - 修改结束：Composer 操作触发滚动到最新消息回调

    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    // Default preserves existing call sites; the layout owner supplies ChatView's owner at integration.
    @StateObject private var localComposerState = ComposerState()
    var sharedComposerState: ComposerState? = nil
    var sharedComposerScope: [String?]? = nil
    var composerState: ComposerState { sharedComposerState ?? localComposerState }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    let send: (String, Bool, [MentionIdentity]) -> Void
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    @Environment(\.chatComposerServices) private var injectedServices
    var services: ChatComposerServices {
        guard let injectedServices else { preconditionFailure("App must inject chat composer actions") }
        return injectedServices
    }
    var resolvedDisabledTitle: String { disabledTitle ?? services.globalMutedMessage }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.sizeCategory) var sizeCategory
    var showPhotoPicker: Bool { get { presentation.showPhotoPicker } nonmutating set { presentation.showPhotoPicker = newValue } }
    var showStickerPhotoPicker: Bool { get { presentation.showStickerPhotoPicker } nonmutating set { presentation.showStickerPhotoPicker = newValue } }
    var showFileImporter: Bool { get { presentation.showFileImporter } nonmutating set { presentation.showFileImporter = newValue } }
    var showContactPicker: Bool { get { presentation.showContactPicker } nonmutating set { presentation.showContactPicker = newValue } }
    var inputHeight: CGFloat { get { presentation.inputHeight } nonmutating set { presentation.inputHeight = newValue } }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var inputSelection: NSRange {
        get { composerSelection.wrappedValue }
        nonmutating set { composerSelection.wrappedValue = newValue }
    }
    var composerSelection: Binding<NSRange> {
        composerState.binding(\.selection, conversationID: conversationID, scope: sharedComposerScope)
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    var expressionTab: ChatExpressionTab { get { presentation.expressionTab } nonmutating set { presentation.expressionTab = newValue } }
    @State var emojiPickerStore: EmojiPickerStoreAdapter?
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var selectedMentionUsers: [MentionIdentity] {
        get { composerState.draft.mentions }
        nonmutating set { composerState.draft.mentions = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    @State var pendingAttachmentSelection: PendingAttachmentSelectionBatch?
    @State var remoteMentionSuggestions: [IMUser] = []
    @State var remoteMentionQuery = ""
    @State var remoteMentionMembersLoading = false
    @State var remoteMentionLookupReady = false
    var isVoiceInputMode: Bool { get { presentation.isVoiceInputMode } nonmutating set { presentation.isVoiceInputMode = newValue } }
    @StateObject var voiceRecorder = VoiceMessageRecorderController()
    @StateObject var voicePreview = VoiceMessagePreviewController()
    var voiceRecordingLifecycle: VoiceRecordingComposerLifecycle { get { presentation.voiceRecordingLifecycle } nonmutating set { presentation.voiceRecordingLifecycle = newValue } }

    var tools: [ChatComposerToolDescriptor] {
        chatComposerToolDescriptors(
            allowsVoiceCall: allowsVoiceCall,
            allowsVideoCall: allowsVideoCall
        )
    }

    func accessibilityHint(for tool: ChatComposerToolDescriptor) -> String {
        switch tool.action {
        case .voiceCall:
            return voiceCallAccessibilityHint
        case .videoCall:
            return videoCallAccessibilityHint
        case .mediaAttachment, .fileAttachment, .contactCard:
            return ""
        }
    }

    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_COMPOSER_HELPERS - 修改开始：Composer 侧附件选择/确认发送定位日志
    func chatBackStuckDiagnostic(_ event: String, force: Bool = false, extra: String = "") {
#if DEBUG
        guard chatBackDiagnosticsEnabled else { return }
        guard force || pendingAttachmentSelection != nil else { return }
        let pendingCount = pendingAttachmentSelection?.selections.count ?? 0
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortChatBackDiagnosticID(conversationID)) input_len=\(input.count) pending_attachments=\(pendingCount)\(suffix)")
#endif
    }

    private static func shortChatBackDiagnosticID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_COMPOSER_HELPERS - 修改结束：Composer 侧附件选择/确认发送定位日志

	    let emojis = [
	        "👍", "👎", "❤️", "😂", "🤣", "🙏", "👏", "🎉",
	        "🔥", "✅", "❌", "👀", "😀", "😃", "😄", "😁",
	        "😆", "😅", "😊", "😉", "😍", "🤩", "😎", "🥳",
	        "🤔", "😢", "😭", "😡", "😱", "👋", "👌", "✌️",
	        "🤞", "🤙", "👈", "👉", "☝️", "✊", "🤝", "💪",
	        "🙌", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
	        "💔", "❤️‍🔥", "💕", "💯", "💬", "📌", "📎", "📝",
	        "📅", "⏰", "🚀", "💡", "🔒", "🔔", "📣", "📈",
	        "⚠️", "❗", "❓", "🔍", "✨", "🌹", "☕", "⭐"
	    ]

	    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
	    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
    // The real ChatView uses its sole shared owner. Existing standalone callers
    // still provide their original external text/reply/panel bindings.
    var composerRenderDraft: ComposerState.Draft {
        var draft = composerState.draft
        if sharedComposerState == nil {
            draft.input = input
            draft.replyQuote = replyQuote; draft.replyContext = replyContext
            draft.mentionAll = mentionAllSelected
            draft.showTools = showTools; draft.showEmoji = showEmoji
        }
        return draft
    }

    var body: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.composerBody?(self)
#endif
        // Preserve the original owner observation lifetime outside account observers.
        // Sample render values here so nested closures carry this draft evaluation.
        ComposerStateObservation(owner: composerState) {
            let draft = composerRenderDraft
            services.observeAccount { authenticated, enterpriseID, identity, actionIdentity in
                authenticatedContent(authenticated: authenticated, enterpriseID: enterpriseID,
                    identity: identity, actionIdentity: actionIdentity, draft: draft)
            }
        }
    }

	    private func authenticatedContent(authenticated: Bool, enterpriseID: String, identity: CurrentUserPresentationStore.Identity, actionIdentity: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
	    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END
        composerFilePresentation(composerMediaPresentation(
        ChatComposerStack(disabled: { disabledNotice(origin: actionIdentity) }, voice: { voiceStatus(origin: actionIdentity) },
            reply: { replyContent(origin: actionIdentity, draft: draft) }, mention: { mentionContent(origin: actionIdentity, draft: draft) },
            input: { inputBar(origin: actionIdentity, draft: draft) }, expression: { expressionContent(origin: actionIdentity, draft: draft) },
            tools: { toolsContent(origin: actionIdentity, draft: draft) }), origin: actionIdentity
        ), origin: actionIdentity)
        .task(id: draft.showEmoji) {
            let showEmoji = draft.showEmoji
            guard showEmoji, services.currentIdentity() == actionIdentity else { return }
            await services.stickers.prepare()
        }
        .task(id: emojiPickerTaskKey(enterpriseID: enterpriseID, identity: identity, isEmojiOpen: draft.showEmoji)) { // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            await synchronizeEmojiPickerRuntime()
        }
        .task(id: ChatComposerMentionTaskKey(query: mentionSearchTaskKey(for: chatComposerMentionQuery(in: draft.input)), session: actionIdentity)) {
            await refreshRemoteMentionSuggestions(for: chatComposerMentionQuery(in: draft.input), origin: actionIdentity)
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            handleVoiceRecordingScenePhase(phase)
        }
        .onChangeCompat(of: authenticated) { _, isAuthenticated in // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            guard !isAuthenticated else { return }
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            services.catalog.reset()
        }
        .onDisappear {
            purgeEmojiPickerIfIdentityChanged()
        }
        .onChangeCompat(of: conversationID) { _, _ in
            cancelVoiceRecordingForNavigation()
            services.stopVoicePlayback()
        }
        .onDisappear {
            cancelVoiceRecordingForNavigation()
            services.stopVoicePlayback()
        }
    }

}

private struct ChatComposerMentionTaskKey: Equatable {
    let query: String
    let session: ChatBubbleSessionIdentity
}
	    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END

// WDT_IOS1_VOICE_PLATFORM_OWNER_BOUNDARY_20261111_BEGIN
@MainActor
final class VoiceMessageRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequesting = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var elapsedMS = 0
    @Published var isCanceling = false
    @Published private(set) var waveformSamples: [Int] = []

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isBusy: Bool {
        isRequesting || isRecording || isFinalizing
    }

    var composerPhase: VoiceRecordingComposerPhase {
        if isRequesting { return .requesting }
        if isRecording { return .recording }
        if isFinalizing { return .finalizing }
        return .idle
    }

    func beginRequesting() -> UInt64? {
        guard !isBusy else { return nil }
        resetRuntime(removeFile: true)
        generation &+= 1
        isRequesting = true
        return generation
    }

    func cancelRequest(_ requestGeneration: UInt64) {
        guard generation == requestGeneration, isRequesting else { return }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @discardableResult
    func cancelPendingStart() -> Bool {
        guard isRequesting else { return false }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return true
    }

    @discardableResult
    func start(requestGeneration: UInt64, onAutoFinished: @escaping () -> Void) throws -> Bool {
        guard generation == requestGeneration, isRequesting else { return false }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMessageRecordings", isDirectory: true)
        let fileURL = directory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        recordingURL = fileURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 64_000
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: TimeInterval(VoiceMessagePayload.maxDurationMS) / 1_000.0) else {
                throw VoiceMessageRecorderError.failedToStart
            }
            self.recorder = recorder
        } catch {
            resetRuntime(removeFile: true)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
        elapsedMS = 0
        waveformSamples = []
        isCanceling = false
        isRequesting = false
        isRecording = true
        startMetering()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceMessagePayload.maxDurationMS) * 1_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.generation == requestGeneration,
                  self.isRecording else { return }
            onAutoFinished()
        }
        return true
    }

    func beginFinalizing() -> UInt64? {
        guard isRecording else { return nil }
        elapsedMS = currentDurationMS()
        isRecording = false
        isFinalizing = true
        meterTimer?.invalidate()
        meterTimer = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        return generation
    }

    func finish(requestGeneration: UInt64, cancelled: Bool) throws -> VoiceMessageRecording? {
        guard generation == requestGeneration, isFinalizing else { return nil }
        let recordedWaveform = waveformSamples
        let url = recordingURL
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        defer {
            removeRecordingFile(url)
            resetRuntime(removeFile: false)
        }
        guard !cancelled else { return nil }
        guard let url else {
            throw VoiceMessageRecorderError.emptyData
        }
        guard let decodedPlayer = try? AVAudioPlayer(contentsOf: url),
              decodedPlayer.prepareToPlay(),
              let durationMS = VoiceMessagePayload.decodedDurationMS(decodedPlayer.duration) else {
            throw VoiceMessageRecorderError.invalidDuration
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw VoiceMessageRecorderError.emptyData
        }
        guard durationMS >= VoiceMessagePayload.minDurationMS else {
            throw VoiceMessageRecorderError.tooShort
        }
        return VoiceMessageRecording(
            data: data,
            name: url.lastPathComponent,
            mimeType: "audio/mp4",
            sizeBytes: Int64(data.count),
            durationMS: durationMS,
            waveform: VoiceMessagePayload.normalizedWaveform(recordedWaveform)
        )
    }

    func cancel() {
        if isRecording, let requestGeneration = beginFinalizing() {
            _ = try? finish(requestGeneration: requestGeneration, cancelled: true)
            return
        }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMeter()
            }
        }
    }

    private func sampleMeter() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        elapsedMS = currentDurationMS()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = Int(round(min(max((Double(power) + 52.0) / 52.0, 0), 1) * 100))
        waveformSamples.append(max(4, normalized))
        if waveformSamples.count > 160 {
            waveformSamples.removeFirst(waveformSamples.count - 160)
        }
    }

    private func currentDurationMS() -> Int {
        guard let recorder else { return 0 }
        let seconds = recorder.currentTime
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return VoiceMessagePayload.normalizedDurationMS(Int((seconds * 1_000).rounded()))
    }

    private func resetRuntime(removeFile: Bool) {
        let url = recordingURL
        meterTimer?.invalidate()
        meterTimer = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        recorder?.stop()
        recorder = nil
        recordingURL = nil
        isRequesting = false
        isRecording = false
        isFinalizing = false
        isCanceling = false
        elapsedMS = 0
        if removeFile {
            removeRecordingFile(url)
        }
    }

    private func removeRecordingFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class VoiceMessagePreviewController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var recording: VoiceMessageRecording?
    @Published private(set) var playbackState: VoiceMessagePlaybackState?
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func setRecording(_ recording: VoiceMessageRecording) {
        stopPlayback(resetProgress: true)
        self.recording = recording
        playbackState = VoiceMessagePlaybackState(
            messageID: "voice-preview",
            elapsedMS: 0,
            durationMS: recording.durationMS
        )
    }

    func togglePlayback() {
        guard let recording else { return }
        if isPlaying {
            pausePlayback()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try self.player ?? AVAudioPlayer(data: recording.data)
            player.delegate = self
            guard player.prepareToPlay(),
                  let durationMS = VoiceMessagePayload.decodedDurationMS(player.duration) else {
                throw VoiceMessageRecorderError.invalidDuration
            }
            let currentElapsedMS = playbackState?.elapsedMS ?? 0
            if currentElapsedMS >= durationMS {
                player.currentTime = 0
                playbackState = VoiceMessagePlaybackState(
                    messageID: "voice-preview",
                    elapsedMS: 0,
                    durationMS: durationMS,
                    isPlaying: false
                )
            }
            guard player.play() else {
                throw VoiceMessageRecorderError.failedToStart
            }
            self.player = player
            isPlaying = true
            refreshProgress()
            startProgressTimer()
        } catch {
            stopPlayback(resetProgress: true)
        }
    }

    func discard() {
        stopPlayback(resetProgress: true)
        recording = nil
        playbackState = nil
    }

    func takeRecordingForSending() -> VoiceMessageRecording? {
        let value = recording
        discard()
        return value
    }

    private func pausePlayback() {
        player?.pause()
        refreshProgress()
        stopProgressTimer()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopPlayback(resetProgress: Bool) {
        stopProgressTimer()
        player?.stop()
        player = nil
        isPlaying = false
        if resetProgress, let recording {
            playbackState = VoiceMessagePlaybackState(messageID: "voice-preview", elapsedMS: 0, durationMS: recording.durationMS)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func refreshProgress() {
        guard let player else { return }
        guard let durationMS = VoiceMessagePayload.decodedDurationMS(player.duration) else {
            stopPlayback(resetProgress: true)
            return
        }
        let elapsedMS = min(durationMS, max(0, Int((player.currentTime * 1_000).rounded())))
        playbackState = VoiceMessagePlaybackState(
            messageID: "voice-preview",
            elapsedMS: elapsedMS,
            durationMS: durationMS,
            isPlaying: player.isPlaying
        )
        guard !player.isPlaying else { return }
        stopProgressTimer()
        isPlaying = false
        if elapsedMS >= durationMS {
            finishPlayback(playerID: ObjectIdentifier(player), reachedEnd: true)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(playerID: playerID, reachedEnd: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(playerID: playerID, reachedEnd: false)
        }
    }

    private func finishPlayback(playerID: ObjectIdentifier, reachedEnd: Bool) {
        guard let finishedPlayer = player,
              ObjectIdentifier(finishedPlayer) == playerID else { return }
        stopProgressTimer()
        if reachedEnd,
           let durationMS = VoiceMessagePayload.decodedDurationMS(finishedPlayer.duration) {
            playbackState = VoiceMessagePlaybackState(
                messageID: "voice-preview",
                elapsedMS: durationMS,
                durationMS: durationMS,
                isPlaying: false
            )
        } else if let recording {
            playbackState = VoiceMessagePlaybackState(
                messageID: "voice-preview",
                elapsedMS: 0,
                durationMS: recording.durationMS,
                isPlaying: false
            )
        }
        finishedPlayer.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// WDT_IOS1_VOICE_PLATFORM_OWNER_BOUNDARY_20261111_END
