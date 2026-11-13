import IM4Features
import IM4Domain
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

extension ChatComposer {
    var activeMentionQuery: String? {
        activeMentionRange.map { String(input[$0]).dropFirst() }.map(String.init)
    }

    private var activeMentionRange: Range<String.Index>? { chatComposerMentionRange(in: input) }

    var mentionSuggestions: [IMUser]? {
        mentionSuggestions(for: activeMentionQuery)
    }

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：Composer 单次重绘复用已解析的 @ 查询，减少输入时重复扫描
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func mentionSuggestions(for query: String?) -> [IMUser]? {
        guard !isDisabled, let query else { return nil }
        let normalizedQuery = IMUserSearchMatcher.normalized(query)
        let localMembers = deduplicatedMentionMembers(mentionMembers).filter { !$0.isCancelledUser }
        let localMatches = normalizedQuery.isEmpty
            ? localMembers
            : localMembers
                .compactMap { user -> (user: IMUser, score: Int, name: String)? in
                    let name = services.remarkPreferredDisplayName(user)
                    guard let score = IMUserSearchMatcher.matchScore(user: user.withName(name), query: query) else {
                        return nil
                    }
                    return (user, score, name)
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map(\.user)

        let shouldUseRemote = remoteMentionQuery == query && (remoteMentionLookupReady || remoteMentionMembersLoading)
        guard shouldUseRemote else {
            return localMatches
        }

        let remoteMembers = deduplicatedMentionMembers(remoteMentionSuggestions).filter { !$0.isCancelledUser }
        let combinedMembers = normalizedQuery.isEmpty
            ? localMatches + remoteMembers
            : remoteMembers + localMatches
        return deduplicatedMentionMembers(combinedMembers)
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    var mentionSearchTaskKey: String {
        mentionSearchTaskKey(for: activeMentionQuery)
    }

    func mentionSearchTaskKey(for query: String?) -> String {
        "\(mentionGroupID)|\(query ?? "__inactive__")"
    }

    var shouldShowMentionAllSuggestion: Bool {
        shouldShowMentionAllSuggestion(for: activeMentionQuery)
    }

    func shouldShowMentionAllSuggestion(for query: String?) -> Bool {
        guard canMentionAll, let query else { return false }
        let normalizedQuery = IMUserSearchMatcher.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let aliases = ["@所有人", "所有人", "all", "suoyouren", "syr"]
        return aliases
            .map(IMUserSearchMatcher.normalized)
            .contains { $0.contains(normalizedQuery) || normalizedQuery.contains($0) }
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

    var canSendInput: Bool {
        containsSendableMessageContent(input)
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func emojiPickerTaskKey(enterpriseID: String, identity: CurrentUserPresentationStore.Identity, isEmojiOpen: Bool? = nil) -> String { // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        services.catalog.taskKey((isEmojiOpen ?? showEmoji) && expressionTab == .emoji, enterpriseID, identity)
    }

    func unicodeEmojiPicker(origin: ChatBubbleSessionIdentity) -> AnyView? {
        guard let emojiPickerStore else { return nil }
        return AnyView(
            EmojiPickerView(
                store: emojiPickerStore,
                onSelect: { item in performInputAction(origin: origin) { insertUnicodeEmoji(item) } }
            )
        )
    }

    @MainActor
    func synchronizeEmojiPickerRuntime() async {
        guard let runtime = services.catalog.currentContext() else {
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            services.catalog.reset()
            return
        }
        if let emojiPickerStore {
            if emojiPickerStore.scope != runtime.scope {
                emojiPickerStore.switchScope(to: runtime.scope)
                services.catalog.reset()
            }
            return
        }
        guard showEmoji, expressionTab == .emoji else { return }
        switch services.catalog.begin(runtime) {
        case .useCatalog(let catalog):
            emojiPickerStore = try? EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .composer
            )
            return
        case .useFallback:
            return
        case .attempt:
            break
        }
        do {
            let catalog = try await EmojiPickerCatalogLoader().load(baseURL: runtime.catalogBaseURL)
            guard services.catalog.currentContext() == runtime else {
                services.catalog.cancelAttempt(runtime)
                return
            }
            let store = try EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .composer
            )
            guard services.catalog.recordSuccess(catalog, runtime) else { return }
            emojiPickerStore = store
        } catch is CancellationError {
            services.catalog.cancelAttempt(runtime)
            return
        } catch let error as URLError where error.code == .cancelled {
            services.catalog.cancelAttempt(runtime)
            return
        } catch {
            let shouldNotify = services.catalog.recordFailure(runtime)
            guard shouldNotify else { return }
            guard showEmoji, expressionTab == .emoji else { return }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("表情目录暂不可用，已使用本地 Emoji")
        }
    }

    private func insertUnicodeEmoji(_ item: EmojiCatalogItem) {
        insertEmojiAtCurrentSelection(item.emoji)
    }

    func insertEmojiAtCurrentSelection(_ emoji: String) {
        let result = insertEmojiAtSelection(
            text: input,
            selectionStart: inputSelection.location,
            selectionEnd: inputSelection.location + inputSelection.length,
            emoji: emoji
        )
        input = result.text
        inputSelection = NSRange(
            location: result.selectionStart,
            length: result.selectionEnd - result.selectionStart
        )
    }

    @MainActor
    func purgeEmojiPickerIfIdentityChanged() {
        guard let emojiPickerStore,
              services.catalog.currentContext()?.scope != emojiPickerStore.scope
        else {
            return
        }
        emojiPickerStore.clearIdentity()
        self.emojiPickerStore = nil
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func toggleVoiceInputMode() {
        guard !isDisabled else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(disabledReason.isEmpty ? resolvedDisabledTitle : disabledReason)
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_TOGGLE - 修改开始：切换语音输入时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_TOGGLE - 修改结束：切换语音输入时回到最新消息
        dismissActiveChatKeyboard()
        withoutComposerLayoutAnimation {
            isVoiceInputMode.toggle()
            if isVoiceInputMode {
                showEmoji = false
                showTools = false
            } else {
                voiceRecorder.cancel()
                voicePreview.discard()
                voiceRecordingLifecycle.clearFeedback()
            }
        }
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    func withoutComposerLayoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_HELPER - 修改开始：Composer 主动操作时请求聊天列表回到最新消息
    func requestLatestScrollForComposerAction() {
        onRequestLatestScroll()
    }
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_HELPER - 修改结束：Composer 主动操作时请求聊天列表回到最新消息

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func beginVoiceRecording(origin: ChatBubbleSessionIdentity) {
        guard !isDisabled else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(disabledReason.isEmpty ? resolvedDisabledTitle : disabledReason)
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_RECORD - 修改开始：开始录音时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_RECORD - 修改结束：开始录音时回到最新消息
        guard let requestGeneration = voiceRecorder.beginRequesting() else { return }
        voiceRecordingLifecycle.beginNewAttempt()
        voicePreview.discard()
        showEmoji = false
        showTools = false
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("正在请求麦克风并启动录音")
        Task { @MainActor in
            guard inputActionIsCurrent(origin),
                  await microphonePermissionGrantedAfterUserAction(),
                  inputActionIsCurrent(origin) else {
                voiceRecorder.cancelRequest(requestGeneration)
                return
            }
            do {
                guard try voiceRecorder.start(requestGeneration: requestGeneration, onAutoFinished: {
                    finishVoiceRecording(cancelled: false)
                }) else { return }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("正在录音")
            } catch {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(BackendUserMessageSanitizer.sanitize(error: error, fallback: "录音启动失败，请重试"))
            }
        }
    }

    func finishVoiceRecording(cancelled: Bool) {
        if voiceRecorder.cancelPendingStart() {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(cancelled ? "已取消语音" : "已取消尚未开始的录音")
            return
        }
        guard let requestGeneration = voiceRecorder.beginFinalizing() else { return }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(cancelled ? "正在取消语音" : "正在结束录音并读取时长")
        Task { @MainActor in
            await Task.yield()
            do {
                guard let recording = try voiceRecorder.finish(
                    requestGeneration: requestGeneration,
                    cancelled: cancelled
                ) else {
                    if cancelled {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("已取消语音")
                    }
                    return
                }
                voiceRecordingLifecycle.clearFeedback()
                voicePreview.setRecording(recording)
                showEmoji = false
                showTools = false
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("语音已就绪")
            } catch VoiceMessageRecorderError.tooShort {
                voiceRecordingLifecycle.presentTooShortFeedback()
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(VoiceRecordingComposerFeedback.tooShort.message)
            } catch {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(BackendUserMessageSanitizer.sanitize(error: error, fallback: "录音失败，请重试"))
            }
        }
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    func cancelVoiceRecordingForNavigation() {
        if voiceRecorder.isBusy {
            voiceRecorder.cancel()
        }
        voicePreview.discard()
        voiceRecordingLifecycle.clearFeedback()
    }

    func handleVoiceRecordingScenePhase(_ phase: ScenePhase) {
        let recordingPhase: VoiceRecordingComposerPhase
        if voicePreview.recording != nil {
            recordingPhase = .preview
        } else {
            recordingPhase = voiceRecorder.composerPhase
        }
        let effect = voiceRecordingLifecycle.transition(
            to: VoiceRecordingAppActivity(scenePhase: phase),
            recordingPhase: recordingPhase
        )
        guard effect == .cancelAndReset else { return }
        voiceRecorder.cancel()
        voicePreview.discard()
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func sendPendingVoiceRecording() {
        guard !isDisabled else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(disabledReason.isEmpty ? resolvedDisabledTitle : disabledReason)
            return
        }
        guard let recording = voicePreview.takeRecordingForSending() else { return }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_SEND - 修改开始：发送语音时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_SEND - 修改结束：发送语音时回到最新消息
        let sentReplyQuote = replyQuote
        let sentReplyContext = sentReplyQuote == nil ? nil : replyContext
        let didStart = services.media.sendVoice(recording, conversationID, sentReplyQuote, sentReplyContext) {
            if voicePreview.recording == nil {
                voicePreview.setRecording(recording)
            }
            if replyQuote == nil {
                replyQuote = sentReplyQuote
                replyContext = sentReplyContext
            }
        }
        guard didStart else {
            voicePreview.setRecording(recording)
            return
        }
        voiceRecordingLifecycle.clearFeedback()
        replyQuote = nil
        replyContext = nil
        showEmoji = false
        showTools = false
    }

    func cancelPendingVoiceRecording() {
        voicePreview.discard()
        voiceRecordingLifecycle.clearFeedback()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("已取消语音")
    }

    private func microphonePermissionGrantedAfterUserAction() async -> Bool {
        let status = currentMicrophoneAuthorizationStatus()
        if status == .granted {
            return true
        }
        if VoiceMessagePermissionGate.shouldRequestMicrophone(
            userTriggered: true,
            businessBlocked: isDisabled,
            status: status
        ) {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("请在系统设置中允许麦克风，用于发送语音消息")
            }
            return granted
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("请在系统设置中允许麦克风，用于发送语音消息")
        return false
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    private func currentMicrophoneAuthorizationStatus() -> VoiceMicrophoneAuthorizationStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func handleToolTap(_ action: ChatComposerToolAction) {
        dismissActiveChatKeyboard()
        switch action {
        case .mediaAttachment:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_MEDIA_TOOL - 修改开始：点击照片/视频工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_MEDIA_TOOL - 修改结束：点击照片/视频工具时回到最新消息
            presentPhotoPicker()
        case .fileAttachment:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_FILE_TOOL - 修改开始：点击文件工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_FILE_TOOL - 修改结束：点击文件工具时回到最新消息
            showFileImporter = true
        case .voiceCall:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_CALL_TOOL - 修改开始：点击通话工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_CALL_TOOL - 修改结束：点击通话工具时回到最新消息
            showTools = false
            startVoiceCall()
        case .videoCall:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VIDEO_CALL_TOOL - 修改开始：点击视频工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VIDEO_CALL_TOOL - 修改结束：点击视频工具时回到最新消息
            showTools = false
            startVideoCall()
        case .contactCard:
            guard !services.contacts.contacts.isEmpty else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("暂无可发送的联系人名片")
                return
            }
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_TOOL - 修改开始：点击名片工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_TOOL - 修改结束：点击名片工具时回到最新消息
            showContactPicker = true
        }
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    private func presentPhotoPicker() {
        showPhotoPicker = true
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func handlePickedAttachmentItems(_ items: [PhotoLibraryPickedItem]) {
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_MEDIA_PICK - 修改开始：定位照片/视频选择后预览生成同步耗时
        let mediaPickDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        chatBackStuckDiagnostic(
            "media_pick_begin",
            force: true,
            extra: "items=\(items.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_MEDIA_PICK - 修改结束：定位照片/视频选择后预览生成同步耗时
        let selections = items.prefix(9).compactMap {
            PendingAttachmentSelection.photoLibrarySelection(item: $0)
        }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_MEDIA_PICK_PREPARED - 修改开始：记录照片/视频选择预览生成结果
        chatBackStuckDiagnostic(
            "media_pick_prepared",
            force: true,
            extra: "items=\(items.count) selections=\(selections.count) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: mediaPickDiagnosticStartedAt))"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_MEDIA_PICK_PREPARED - 修改结束：记录照片/视频选择预览生成结果
        guard !selections.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("照片或视频读取失败，请重新选择")
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_MEDIA_PICKED - 修改开始：照片/视频选择完成后回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_MEDIA_PICKED - 修改结束：照片/视频选择完成后回到最新消息
        if items.count > 9 {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("一次最多选择 9 张照片或视频")
        }
        pendingAttachmentSelection = PendingAttachmentSelectionBatch(selections: selections)
        showTools = false
    }

    func handlePickedStickerItems(_ items: [PhotoLibraryPickedItem]) {
        guard let item = items.first,
              let data = item.data else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast("表情数据读取失败，请重新选择")
            return
        }
        expressionTab = .stickers
        showEmoji = true
        showTools = false
        services.stickers.upload(data, stickerPhotoLibraryFileName(contentTypes: item.contentTypes), conversationID)
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    private func stickerPhotoLibraryFileName(contentTypes: [UTType]) -> String {
        let preferredType = contentTypes.first { $0.conforms(to: UTType(filenameExtension: "gif") ?? .image) }
            ?? contentTypes.first { $0.conforms(to: .png) }
            ?? contentTypes.first { $0.conforms(to: .jpeg) }
            ?? contentTypes.first { $0.conforms(to: .image) }
        let rawExtension = preferredType?.preferredFilenameExtension?.lowercased() ?? "jpg"
        let normalizedExtension = rawExtension == "jpeg" ? "jpg" : rawExtension
        return "我的表情.\(normalizedExtension)"
    }

    func sendCurrentInput() {
        let draft = normalizedSendableMessageText(input)
        guard !draft.isEmpty else { return }
        let shouldMentionAll = mentionAllSelected && draft.contains("@所有人")
        let activeMentions = deduplicatedSelectedMentionUsers(in: draft)
        send(draft, shouldMentionAll, activeMentions)
        mentionAllSelected = false
        selectedMentionUsers.removeAll()
    }

    func insertMention(_ user: IMUser) {
        guard let range = activeMentionRange else { return }
        let replacement = "@\(mentionVisibleDisplayName(for: user)) "
        let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count
        input.replaceSubrange(range, with: replacement)
        inputSelection = NSRange(location: insertionEnd, length: 0)
        rememberMention(user)
        showEmoji = false
        showTools = false
    }

    func insertMentionAll() {
        guard let range = activeMentionRange else { return }
        let replacement = "@所有人 "
        let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count
        input.replaceSubrange(range, with: replacement)
        inputSelection = NSRange(location: insertionEnd, length: 0)
        mentionAllSelected = true
        showEmoji = false
        showTools = false
    }

    private func deduplicatedMentionMembers(_ users: [IMUser]) -> [IMUser] {
        var seen = Set<String>()
        return users.filter { user in
            let key = mentionUserKey(for: user)
            return seen.insert(key).inserted
        }
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func refreshRemoteMentionSuggestions(for query: String?, origin: ChatBubbleSessionIdentity) async {
        guard services.currentIdentity() == origin else { return }
        guard !isDisabled,
              let query,
              !mentionGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remoteMentionQuery = ""
            remoteMentionSuggestions = []
            remoteMentionMembersLoading = false
            remoteMentionLookupReady = false
            return
        }
        remoteMentionQuery = query
        remoteMentionMembersLoading = true
        remoteMentionLookupReady = false
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        guard !Task.isCancelled, services.currentIdentity() == origin else { return }
        let users = await services.searchMentions(mentionGroupID, query)
        guard !Task.isCancelled, services.currentIdentity() == origin else { return }
        remoteMentionSuggestions = users
        remoteMentionQuery = query
        remoteMentionMembersLoading = false
        remoteMentionLookupReady = true
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

    private func rememberMention(_ user: IMUser) {
        let mention = MentionIdentity(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: mentionVisibleDisplayName(for: user)
        )
        guard !mention.id.isEmpty else { return }
        selectedMentionUsers.removeAll { $0.id == mention.id || $0.mentionToken == mention.mentionToken }
        selectedMentionUsers.append(mention)
    }

    private func deduplicatedSelectedMentionUsers(in draft: String) -> [MentionIdentity] {
        var seen = Set<String>()
        return selectedMentionUsers.filter { mention in
            guard draft.contains(mention.mentionToken), !mention.id.isEmpty else { return false }
            return seen.insert(mention.id).inserted
        }
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110: original business/action order retained in App.
