import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_TRANSCRIPT_SCROLL_VALUE_BOUNDARY_20261111_BEGIN
public struct ChatTranscriptScrollSurface<Content: View, HistoryStatus: View>: View {
    let readLayout: ChatScrollReadLayout
    let usesNativeGeometry: Bool
    let coordinateSpaceName: String
    let hidesGIFPlayback: Bool
    let mediaScrollActivity: ChatMediaScrollActivity
    let metricsChanged: (ChatScrollMetricsSnapshot) -> Void
    let incomingRowChanged: (ChatIncomingRowPreferenceKey.Value) -> Void
    let messageTopsChanged: (ChatMessageTopPreferenceKey.Value) -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var historyStatus: () -> HistoryStatus

    public var body: some View {
        GeometryReader { viewportProxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) { content() }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .background {
                        if !usesNativeGeometry {
                            GeometryReader { contentProxy in
                                let frame = contentProxy.frame(in: .named(coordinateSpaceName))
                                Color.clear.preference(key: ChatScrollMetricsPreferenceKey.self,
                                    value: readLayout.metrics(viewportHeight: viewportProxy.size.height,
                                        contentMinY: frame.minY, contentMaxY: frame.maxY))
                            }
                        }
                    }
            }
            .chatObserveScrollGeometry(enabled: usesNativeGeometry, readLayout: readLayout, onMetrics: metricsChanged)
            .environment(\.stickerGIFPlaybackViewport, hidesGIFPlayback ? .zero : viewportProxy.frame(in: .global))
            .environment(\.chatMediaScrollActivity, mediaScrollActivity)
            .chatTrackScrollPhase(mediaScrollActivity)
            .chatScrollDismissesKeyboardOnDrag()
            .coordinateSpace(name: coordinateSpaceName)
            .overlay(alignment: .top) { historyStatus().padding(.top, 10) }
        }
        .onPreferenceChange(ChatScrollMetricsPreferenceKey.self) { metrics in
            guard !usesNativeGeometry else { return }
            metricsChanged(metrics)
        }
        .onPreferenceChange(ChatIncomingRowPreferenceKey.self, perform: incomingRowChanged)
        .onPreferenceChange(ChatMessageTopPreferenceKey.self, perform: messageTopsChanged)
    }

    public init(readLayout: ChatScrollReadLayout,
        usesNativeGeometry: Bool,
        coordinateSpaceName: String,
        hidesGIFPlayback: Bool,
        mediaScrollActivity: ChatMediaScrollActivity,
        metricsChanged: @escaping (ChatScrollMetricsSnapshot) -> Void,
        incomingRowChanged: @escaping (ChatIncomingRowPreferenceKey.Value) -> Void,
        messageTopsChanged: @escaping (ChatMessageTopPreferenceKey.Value) -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder historyStatus: @escaping () -> HistoryStatus) {
        self.readLayout = readLayout
        self.usesNativeGeometry = usesNativeGeometry
        self.coordinateSpaceName = coordinateSpaceName
        self.hidesGIFPlayback = hidesGIFPlayback
        self.mediaScrollActivity = mediaScrollActivity
        self.metricsChanged = metricsChanged
        self.incomingRowChanged = incomingRowChanged
        self.messageTopsChanged = messageTopsChanged
        self.content = content
        self.historyStatus = historyStatus
    }
}
// WDT_IOS1_TRANSCRIPT_SCROLL_VALUE_BOUNDARY_20261111_END

extension View {
    @ViewBuilder
    // WDT_CHAT_KEYBOARD_INSET_20261021: any transcript scroll dismisses, not just a completed interactive pull.
    func chatScrollDismissesKeyboardOnDrag() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}
