import SwiftUI
import IM4DesignSystem

public struct ChatScreenLayout<Content: View, ActionOverlay: View, SenderOverlay: View, Header: View>: View {
    let allowsBackSwipe: Bool
    let isComposerEditing: Bool
    let isHistorySearchFocused: Bool
    let content: () -> Content
    let actionOverlay: () -> ActionOverlay
    let senderOverlay: () -> SenderOverlay
    let header: () -> Header
    public init(allowsBackSwipe: Bool, isComposerEditing: Bool, isHistorySearchFocused: Bool,
        @ViewBuilder content: @escaping () -> Content, @ViewBuilder actionOverlay: @escaping () -> ActionOverlay,
        @ViewBuilder senderOverlay: @escaping () -> SenderOverlay, @ViewBuilder header: @escaping () -> Header) {
        self.allowsBackSwipe = allowsBackSwipe; self.isComposerEditing = isComposerEditing
        self.isHistorySearchFocused = isHistorySearchFocused; self.content = content
        self.actionOverlay = actionOverlay; self.senderOverlay = senderOverlay; self.header = header
    }
    public var body: some View {
        ZStack {
            AuroraBackground()
            AnyView(content())
            AnyView(actionOverlay())
            AnyView(senderOverlay())
        }
        .background(
            // WDT_CHAT_EDGE_BACK_FIX_20261102: retain UIKit's interactive, cancellable edge-back transition.
            ChatInteractiveBackSwipeInstaller(allowsBackSwipe: allowsBackSwipe)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            header()
        }
        // WDT_CHAT_KEYBOARD_INSET_20261021: keep the device safe area; only release the inactive keyboard region.
        .ignoresSafeArea(.keyboard, edges: chatIgnoredKeyboardEdges(
            composerIsEditing: isComposerEditing,
            searchIsFocused: isHistorySearchFocused
        ))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .im4ToolbarTabBarHiddenCompat()
    }
}

// WDT_IOS1_CHAT_TOP_CONTEXT_FEATURE_20261111_BEGIN
@MainActor
@ViewBuilder
public func chatTopContextContent<Announcement: View, Pinned: View, Search: View>(
    hasPinnedMessages: Bool,
    @ViewBuilder announcement: () -> Announcement,
    @ViewBuilder pinned: () -> Pinned,
    @ViewBuilder search: () -> Search
) -> some View {
    announcement()
    if hasPinnedMessages {
        pinned()
    }
    search()
}
// WDT_IOS1_CHAT_TOP_CONTEXT_FEATURE_20261111_END

public struct ChatScreenColumn<Top: View, Timeline: View, Mute: View, Composer: View>: View {
    let top: () -> Top
    let timeline: () -> Timeline
    let mute: () -> Mute
    let composer: () -> Composer
    public init(@ViewBuilder top: @escaping () -> Top, @ViewBuilder timeline: @escaping () -> Timeline,
        @ViewBuilder mute: @escaping () -> Mute, @ViewBuilder composer: @escaping () -> Composer) {
        self.top = top; self.timeline = timeline; self.mute = mute; self.composer = composer
    }
    public var body: some View {
        VStack(spacing: 0) { top(); timeline(); mute(); composer() }
    }
}
