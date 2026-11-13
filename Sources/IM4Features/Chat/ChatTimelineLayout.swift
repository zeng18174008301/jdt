import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct ChatTimelineRowDecoration<Content: View>: View {
    let message: ChatMessage
    let conversationID: String
    let coordinateSpaceName: String
    let visibilityEpoch: Int
    let readTargetID: String?
    let isFocused: Bool
    let isBatchSelectionActive: Bool
    let batchSelected: Bool
    let batchDisabledReason: String?
    let toggleSelection: () -> Void
    @ViewBuilder let content: () -> Content
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if isBatchSelectionActive {
                    Button {
                        toggleSelection()
                    } label: {
                        Image(
                            systemName: batchSelected
                                ? "checkmark.circle.fill"
                                : (batchDisabledReason == nil ? "circle" : "nosign")
                        )
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(
                                batchSelected
                                    ? IMColor.brand
                                    : (batchDisabledReason == nil ? IMColor.muted : IMColor.danger)
                            )
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(batchDisabledReason != nil)
                    .accessibilityLabel(
                        batchDisabledReason
                            ?? (batchSelected ? "取消选择消息" : "选择消息")
                    )
                    .accessibilityValue(batchSelected ? "已选择" : "未选择")
                }
                content()
            }
            if isBatchSelectionActive, let batchDisabledReason {
                Text(batchDisabledReason)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.leading, 40)
                    .accessibilityLabel(batchDisabledReason)
            }
        }
        .background {
            // WDT_CHAT_UNREAD_BADGE_20261021: measure the actual confirmed tail row, not just the lazy stack bounds.
            if message.id == readTargetID, message.channelSeq > 0 {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatIncomingRowPreferenceKey.self,
                        value: ChatIncomingRowGeometry(
                            token: "\(conversationID):\(message.channelSeq)",
                            frame: proxy.frame(in: .named(coordinateSpaceName)),
                            epoch: visibilityEpoch
                        )
                    )
                }
            }
        }
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(IMColor.brand.opacity(0.10))
            }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(IMColor.brand.opacity(0.55), lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    public init(message: ChatMessage,
        conversationID: String,
        coordinateSpaceName: String,
        visibilityEpoch: Int,
        readTargetID: String? = nil,
        isFocused: Bool,
        isBatchSelectionActive: Bool,
        batchSelected: Bool,
        batchDisabledReason: String? = nil,
        toggleSelection: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content) {
        self.message = message
        self.conversationID = conversationID
        self.coordinateSpaceName = coordinateSpaceName
        self.visibilityEpoch = visibilityEpoch
        self.readTargetID = readTargetID
        self.isFocused = isFocused
        self.isBatchSelectionActive = isBatchSelectionActive
        self.batchSelected = batchSelected
        self.batchDisabledReason = batchDisabledReason
        self.toggleSelection = toggleSelection
        self.content = content
    }
}

public struct ChatTimelineItemLayout<Row: View, Anchor: View>: View {
    let item: ChatMessageTimelineItem
    @ViewBuilder let row: () -> Row
    @ViewBuilder let anchor: () -> Anchor
    @ViewBuilder public var body: some View {
        switch item.kind {
        case .timeSeparator(let text): MessageTimeSeparator(text: text).padding(.bottom, 8)
        case .unreadDivider(let count): NewMessagesDivider(count: count).padding(.bottom, 8)
        case .historyAnchor: anchor()
        case .message: row().padding(.bottom, 8)
        }
    }

    public init(item: ChatMessageTimelineItem,
        @ViewBuilder row: @escaping () -> Row,
        @ViewBuilder anchor: @escaping () -> Anchor) {
        self.item = item
        self.row = row
        self.anchor = anchor
    }
}
public struct ChatMessageHistoryAnchor: View {
    let messageID: String
    let coordinateSpaceName: String
    let measuresTop: Bool
    public var body: some View {
        // Retain the actual 8pt scroll rectangle and the original measurement gate.
        Color.clear.frame(height: 8).background {
            if measuresTop {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(coordinateSpaceName))
                    Color.clear.preference(key: ChatMessageTopPreferenceKey.self, value: [messageID: frame.minY])
                }
            }
        }
    }

    public init(messageID: String,
        coordinateSpaceName: String,
        measuresTop: Bool) {
        self.messageID = messageID
        self.coordinateSpaceName = coordinateSpaceName
        self.measuresTop = measuresTop
    }
}
public struct ChatTimelineBottomAnchor: View {
    let height: CGFloat
    let anchorID: String
    public var body: some View {
        Color.clear.frame(height: height).padding(.bottom, 12).id(anchorID)
    }

    public init(height: CGFloat,
        anchorID: String) {
        self.height = height
        self.anchorID = anchorID
    }
}
public struct ChatTranscriptList<Empty: View, ItemContent: View, Bottom: View>: View {
    let items: [ChatMessageTimelineItem]
    @ViewBuilder let empty: () -> Empty
    @ViewBuilder let itemContent: (ChatMessageTimelineItem) -> ItemContent
    @ViewBuilder let bottom: () -> Bottom
    public var body: some View {
        empty()
        ForEach(items) { item in
            ChatMessageLazyLeaf { itemContent(item) }.id(item.id)
        }
        bottom()
    }

    public init(items: [ChatMessageTimelineItem],
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder itemContent: @escaping (ChatMessageTimelineItem) -> ItemContent,
        @ViewBuilder bottom: @escaping () -> Bottom) {
        self.items = items
        self.empty = empty
        self.itemContent = itemContent
        self.bottom = bottom
    }
}
public struct ChatEmptyHistoryLayout<Content: View>: View {
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    @ViewBuilder let content: () -> Content
    public var body: some View {
        content().padding(.top, 28).padding(.horizontal, 18).padding(.bottom, 8)
    }
}
