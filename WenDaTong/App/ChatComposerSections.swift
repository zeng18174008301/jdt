import IM4Features
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
extension ChatComposer {
    func disabledNotice(origin: ChatBubbleSessionIdentity) -> some View {
        ChatComposerDisabledNotice(isDisabled: isDisabled, showsDisabledNotice: showsDisabledNotice,
            disabledTitle: resolvedDisabledTitle, disabledReason: disabledReason, friendActionTitle: friendActionTitle,
            isApplyingFriend: isApplyingFriend, applyFriend: { performInputAction(origin: origin, applyFriend) })
    }
    func voiceStatus(origin: ChatBubbleSessionIdentity) -> some View {
        ChatComposerVoiceStatus(isRecording: voiceRecorder.isRecording, elapsedMS: voiceRecorder.elapsedMS,
            waveform: voiceRecorder.waveformSamples, isCanceling: voiceRecorder.isCanceling,
            isVoiceInputMode: isVoiceInputMode, feedback: voiceRecordingLifecycle.feedback,
            previewInput: voicePreview.presentationInput, togglePlayback: voicePreview.togglePlayback,
            send: { performInputAction(origin: origin, sendPendingVoiceRecording) }, cancel: cancelPendingVoiceRecording)
    }
    func replyContent(origin: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
        ChatComposerReplyPreview(quote: draft.replyQuote, cancel: {
            performInputAction(origin: origin) {
                replyQuote = nil
                replyContext = nil
            }
        }) { quote in
            ReplyQuoteBlock(quote: quote, context: draft.replyContext, outgoing: false, compact: true)
        }
    }

    @ViewBuilder
    func mentionContent(origin actionIdentity: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
            let query = chatComposerMentionQuery(in: draft.input)
            if let suggestions = mentionSuggestions(for: query) {
                let onSelect: (IMUser) -> Void = { user in performInputAction(origin: actionIdentity) { insertMention(user) } }
                let onSelectAll: () -> Void = { performInputAction(origin: actionIdentity, insertMentionAll) }
#if DEBUG
                let _ = ChatComposerInputDiagnostics.mentionActions?(conversationID, onSelect, onSelectAll)
#endif
                MentionSuggestionPanel(
	                    suggestions: suggestions,
	                    showsMentionAll: shouldShowMentionAllSuggestion(for: query),
	                    hasQuery: IMUserSearchMatcher.normalized(query ?? "").isEmpty == false,
	                    isLoading: (mentionMembersLoading || remoteMentionMembersLoading) && suggestions.isEmpty,
	                    onSelect: onSelect,
	                    onSelectAll: onSelectAll
	                )
            }

    }

    @ViewBuilder
    func inputBar(origin actionIdentity: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
            let renderInput = ChatComposerTextEntryInput(isDisabled: isDisabled, canSend: containsSendableMessageContent(draft.input))
            let query = chatComposerMentionQuery(in: draft.input)
	            ChatComposerInputBar(isVoiceInputMode: isVoiceInputMode, toggleVoice: { performInputAction(origin: actionIdentity, toggleVoiceInputMode) },
                toggleTools: {
                        guard inputActionIsCurrent(actionIdentity) else { return }
                        guard !isDisabled else {
                            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ services.toast(disabledReason)
                            return
                        }
                        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_PLUS_VOICE_MODE - 修改开始：语音模式点击 + 时回到最新消息
                        requestLatestScrollForComposerAction()
                        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_PLUS_VOICE_MODE - 修改结束：语音模式点击 + 时回到最新消息
                        dismissActiveChatKeyboard()
                        withoutComposerLayoutAnimation {
                            showTools.toggle()
                            showEmoji = false
                        }
                }, voicePad: {
                    VoiceRecordPad(
                        isRecording: voiceRecorder.isRecording,
                        isRequesting: voiceRecorder.isRequesting,
                        isFinalizing: voiceRecorder.isFinalizing,
                        elapsedMS: voiceRecorder.elapsedMS,
                        isCanceling: voiceRecorder.isCanceling,
                        start: { performInputAction(origin: actionIdentity) { beginVoiceRecording(origin: actionIdentity) } },
                        finish: { cancelled in finishVoiceRecording(cancelled: cancelled) },
                        updateCanceling: { voiceRecorder.isCanceling = $0 }
                    )
                }, textEntry: {
                    ChatComposerTextEntry(
                        input: renderInput,
                        text: $input, dynamicHeight: $presentation.inputHeight, selection: composerSelection,
                        actions: textEntryActions(origin: actionIdentity, renderInput: renderInput, mentionQuery: query)
                    )                })
    }

    @ViewBuilder
    func expressionContent(origin: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
	            if draft.showEmoji && !isDisabled {
	                ChatExpressionPanel(
	                    stickerStore: services.stickers.store,
	                    selectedTab: $presentation.expressionTab,
	                    emojis: emojis,
	                    insertEmoji: { emoji in
	                        performInputAction(origin: origin) { insertEmojiAtCurrentSelection(emoji) }
	                    },
                        addStickerPhoto: {
                            performInputAction(origin: origin) { showStickerPhotoPicker = true }
                        },
	                    sendSticker: { item in
                        guard inputActionIsCurrent(origin) else { return }
                        let sentReplyQuote = replyQuote
                        let activeReplyContext = sentReplyQuote == nil ? nil : replyContext
                        let didStart = services.stickers.send(item, conversationID, sentReplyQuote, activeReplyContext) {
                            if replyQuote == nil {
                                replyQuote = sentReplyQuote
                                replyContext = activeReplyContext
                            }
                        }
                        guard didStart else { return }
                        replyQuote = nil
                        replyContext = nil
                        showEmoji = false
                        showTools = false
                    },
                        unicodePicker: unicodeEmojiPicker(origin: origin),
                        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
                        prepareStickers: { if inputActionIsCurrent(origin) { await services.stickers.prepare() } },
                        refreshStickers: { performInputAction(origin: origin, services.stickers.refresh) },
                        stickerThumbnailURL: { item in services.stickers.thumbnailURL(item) },
                        retrySticker: { item in performInputAction(origin: origin) { services.stickers.retry(item) } },
                        deleteSticker: { item in performInputAction(origin: origin) { services.stickers.delete(item) } },
                        moveSticker: { item, direction in
                            performInputAction(origin: origin) { services.stickers.move(item, direction) }
                        }
                        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

    }

    func toolsContent(origin: ChatBubbleSessionIdentity, draft: ComposerState.Draft) -> some View {
        ChatComposerToolGrid(isVisible: draft.showTools && !isDisabled, tools: tools,
            select: { action in performInputAction(origin: origin) { handleToolTap(action) } }, accessibilityHint: accessibilityHint(for:))
    }

}
// WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

// WDT_IOS1_VOICE_PREVIEW_INPUT_BOUNDARY_20261111_BEGIN
extension VoiceMessagePreviewController {
    var presentationInput: VoiceRecordingPreviewInput? {
        guard let recording else { return nil }
        return VoiceRecordingPreviewInput(durationMS: recording.durationMS, waveform: recording.waveform,
            isPlaying: isPlaying, progress: playbackState?.progress ?? 0,
            remainingLabel: playbackState?.remainingLabel)
    }
}
// WDT_IOS1_VOICE_PREVIEW_INPUT_BOUNDARY_20261111_END

// WDT_IOS1_STICKER_PANEL_OWNER_BOUNDARY_20261111_BEGIN
struct ChatExpressionPanel: View {
    @ObservedObject var stickerStore: StickerStore
    @Binding var selectedTab: ChatExpressionTab
    let emojis: [String]
    let insertEmoji: (String) -> Void
    let addStickerPhoto: () -> Void
    let sendSticker: (StickerLibraryItem) -> Void
    var unicodePicker: AnyView? = nil
    let prepareStickers: @MainActor () async -> Void
    let refreshStickers: @MainActor () -> Void
    let stickerThumbnailURL: @MainActor (StickerLibraryItem) -> String
    let retrySticker: @MainActor (StickerLibraryItem) -> Void
    let deleteSticker: @MainActor (StickerLibraryItem) -> Void
    let moveSticker: @MainActor (StickerLibraryItem, Int) -> Void

    var body: some View {
        let input = ChatStickerPanelInput(items: stickerStore.myStickers.map { item in
            ChatStickerPanelItem(item: item, isDeleting: stickerStore.isDeleting(item), isSorting: stickerStore.isSorting(item))
        }, isManifestRefreshing: stickerStore.isManifestRefreshing, manifestErrorMessage: stickerStore.manifestErrorMessage)
        return ChatExpressionPanelContent(input: input, selectedTab: $selectedTab, emojis: emojis,
            insertEmoji: insertEmoji, addStickerPhoto: addStickerPhoto, sendSticker: sendSticker,
            unicodePicker: unicodePicker, prepareStickers: prepareStickers, refreshStickers: refreshStickers,
            stickerThumbnailURL: stickerThumbnailURL, retrySticker: retrySticker,
            deleteSticker: { item in
                deleteSticker(item)
                return stickerStore.myStickers.count
            }, moveSticker: moveSticker)
    }
}
// WDT_IOS1_STICKER_PANEL_OWNER_BOUNDARY_20261111_END
