import SwiftUI

@MainActor
public final class ChatComposerPresentationState: ObservableObject {
    @Published public var showPhotoPicker = false
    @Published public var showStickerPhotoPicker = false
    @Published public var showFileImporter = false
    @Published public var showContactPicker = false
    @Published public var inputHeight: CGFloat = 42
    @Published public var expressionTab: ChatExpressionTab = .emoji
    @Published public var isVoiceInputMode = false
    @Published public var voiceRecordingLifecycle = VoiceRecordingComposerLifecycle()
    public init() {}
}
