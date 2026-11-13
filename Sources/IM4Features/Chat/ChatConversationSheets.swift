import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

public struct PinnedMessagesContent: View {
    let conversationID: String // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110
    let onSelect: (ChatMessage) -> Void
    let onUnpin: (ChatMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    let messages: [ChatMessage]
    let senderNames: [String: String]

    private func displaySenderName(for message: ChatMessage) -> String { senderNames[message.id] ?? "未知用户" }
    public var body: some View { pinnedContent(messages: messages) }

    private func pinnedContent(messages: [ChatMessage]) -> some View { // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetHeader(symbol: "pin.fill", title: "置顶消息", subtitle: "点击任意置顶消息后返回会话并定位到原消息。", showsCloseButton: true)
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "pin.slash")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(IMColor.muted.opacity(0.10)))
                                Text("暂无置顶消息")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("群主或管理员置顶消息后，会在这里集中查看和定位。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .im4PlainCard(radius: 22)
                        }
                        ForEach(messages) { message in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    dismiss()
                                    onSelect(message)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: message.kind == .file ? "doc.richtext.fill" : (message.kind == .contactCard ? "person.crop.rectangle" : "text.bubble.fill"))
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(IMColor.warning)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(IMColor.warning.opacity(0.12)))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(message.kind == .file || message.kind == .contactCard ? (message.attachmentName ?? message.text) : message.text)
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.ink)
                                                .lineLimit(2)
                                            Text("\(displaySenderName(for: message)) · \(message.time)")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.to.line.compact")
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundStyle(IMColor.muted)
                                    }
                                }
                                .buttonStyle(.plain)
                                Button {
                                    onUnpin(message)
                                } label: {
                                    Image(systemName: "pin.slash.fill")
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(IMColor.warning)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(IMColor.warning.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("取消置顶")
                            }
                            .im4PlainCard(radius: 20)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    public init(conversationID: String,
        onSelect: @escaping (ChatMessage) -> Void,
        onUnpin: @escaping (ChatMessage) -> Void,
        messages: [ChatMessage],
        senderNames: [String: String]) {
        self.conversationID = conversationID
        self.onSelect = onSelect
        self.onUnpin = onUnpin
        self.messages = messages
        self.senderNames = senderNames
    }
}

public struct GroupAnnouncementContent: View {
    let group: GroupInfo
    let announcementID: String?
    let onClose: (() -> Void)?
    let currentGroup: GroupInfo
    let currentAnnouncement: GroupAnnouncement?
    let canPublish: Bool
    let actions: ChatAnnouncementActions
    @Environment(\.dismiss) private var dismiss
    @State private var showPublisher = false
    @State private var didRunCloseAction = false

    private var publisherName: String {
        if let createdBy = currentAnnouncement?.createdBy, !createdBy.isEmpty {
            return createdBy
        }
        return currentGroup.owner.isEmpty ? "群管理员" : currentGroup.owner
    }

    private var announcementTime: String {
        if let publishedAt = currentAnnouncement?.publishedAt, !publishedAt.isEmpty {
            return publishedAt
        }
        return currentAnnouncement?.createdAt.isEmpty == false ? currentAnnouncement!.createdAt : "刚刚"
    }

    private var displayContent: String {
        groupAnnouncementDisplayContent(
            content: currentAnnouncement?.content,
            summary: currentAnnouncement?.summary,
            groupNotice: currentGroup.notice
        )
    }

    private var hasVisibleAnnouncementContent: Bool {
        groupAnnouncementHasVisibleContent(
            content: currentAnnouncement?.content,
            summary: currentAnnouncement?.summary,
            groupNotice: currentGroup.notice
        )
    }

    private var displayTitle: String {
        let title = currentAnnouncement?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "群公告" : title
    }

    private func closeSheet() {
        if !didRunCloseAction {
            didRunCloseAction = true
            onClose?()
        }
        dismiss()
    }

    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    public var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.announcement?($showPublisher)
#endif
        return announcementContent
    }

    // WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_BEGIN
    private var announcementHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text("群公告")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(currentGroup.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
                if hasVisibleAnnouncementContent {
                    StatusPill(title: "当前有效", color: IMColor.success)
                }
                Button {
                    closeSheet()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.86)))
                        .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            if hasVisibleAnnouncementContent {
                HStack(spacing: 8) {
                    Label("发布人 \(publisherName)", systemImage: "person.crop.circle.fill")
                    Label(announcementTime, systemImage: "clock.fill")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
            }
        }
        .im4GlassCard(radius: 28)
    }
    // WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_END

    // WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_BEGIN
    private var announcementContent: some View {
        Group {
            if showPublisher {
                GroupAnnouncementEditorContent(
                    group: currentGroup,
                    publishAction: actions.publish, invalidContent: actions.emptyContent,
                    existingAnnouncement: currentAnnouncement,
                    dismissAfterPublish: false,
                    onCancel: {
                        showPublisher = false
                    },
                    onPublished: {
                        showPublisher = false
                        if let announcementID = currentAnnouncement?.id {
                            actions.reload(announcementID)
                        }
                    }
                )
            } else {
                NavigationStackCompat {
                    ZStack {
                        AuroraBackground()
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                // WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110
                                announcementHeader

                                if hasVisibleAnnouncementContent {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(displayTitle)
                                            .font(.system(size: 20, weight: .black))
                                            .foregroundStyle(IMColor.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Divider()
                                            .overlay(IMColor.line)
                                        Text(displayContent)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(IMColor.ink)
                                            .lineSpacing(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .im4PlainCard(radius: 24)

                                    if let readCountSummary = currentAnnouncement?.readCountSummary {
                                        Label(readCountSummary, systemImage: "chart.bar.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(IMColor.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(12)
                                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.07)))
                                            .accessibilityIdentifier("group_announcement_read_counts")
                                    }
                                } else {
                                    EmptyStateView(
                                        symbol: "megaphone",
                                        title: "暂无群公告",
                                        subtitle: canPublish ? "发布后会同步给群成员。" : "群管理员发布后会显示在这里。"
                                    )
                                    .im4PlainCard(radius: 24)
                                }

                                HStack(spacing: 10) {
                                    if hasVisibleAnnouncementContent {
                                        Button {
                                            actions.copy(displayContent)
                                        } label: {
                                            Label("复制公告", systemImage: "doc.on.doc.fill")
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.brand)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 48)
                                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if canPublish {
                                        Button {
                                            showPublisher = true
                                        } label: {
                                            Label(currentAnnouncement == nil ? "发布公告" : "编辑公告", systemImage: "megaphone.fill")
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.brand)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 48)
                                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    PrimaryButton(title: "我知道了", systemImage: "checkmark") {
                                        closeSheet()
                                    }
                                }
                            }
                            .padding(18)
                        }
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .im4PresentationDragIndicatorCompat(.visible)
        .onAppear { actions.load() }
        .onDisappear {
            if !didRunCloseAction {
                didRunCloseAction = true
                onClose?()
            }
        }
	    }

    public init(group: GroupInfo,
        announcementID: String? = nil,
        onClose: (() -> Void)? = nil,
        currentGroup: GroupInfo,
        currentAnnouncement: GroupAnnouncement? = nil,
        canPublish: Bool,
        actions: ChatAnnouncementActions) {
        self.group = group
        self.announcementID = announcementID
        self.onClose = onClose
        self.currentGroup = currentGroup
        self.currentAnnouncement = currentAnnouncement
        self.canPublish = canPublish
        self.actions = actions
    }
}
// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_END

struct GroupAnnouncementEditorContent: View {
    let group: GroupInfo
    let existingAnnouncement: GroupAnnouncement?
    var dismissAfterPublish: Bool = true
    var onCancel: (() -> Void)? = nil
    var onPublished: (() -> Void)? = nil

    let publishAction: (String, String, @escaping (Bool) -> Void) -> Bool
    let invalidContent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle: String
    @State private var draftContent: String
    @State private var isPublishing = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case content
    }

    init(
        group: GroupInfo,
        publishAction: @escaping (String, String, @escaping (Bool) -> Void) -> Bool,
        invalidContent: @escaping () -> Void,
        existingAnnouncement: GroupAnnouncement? = nil,
        dismissAfterPublish: Bool = true,
        onCancel: (() -> Void)? = nil,
        onPublished: (() -> Void)? = nil
    ) {
        self.group = group
        self.publishAction = publishAction
        self.invalidContent = invalidContent
        self.existingAnnouncement = existingAnnouncement
        self.dismissAfterPublish = dismissAfterPublish
        self.onCancel = onCancel
        self.onPublished = onPublished
        _draftTitle = State(initialValue: existingAnnouncement?.title ?? "群公告")
        _draftContent = State(initialValue: existingAnnouncement?.content ?? "")
    }

    private var isEditing: Bool { existingAnnouncement != nil }

    private var trimmedTitle: String {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "群公告" : title
    }

    private var trimmedContent: String {
        draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var publishDisabled: Bool {
        isPublishing || trimmedContent.isEmpty
    }

    private func publish() {
        guard !isPublishing else { return }
        guard !trimmedContent.isEmpty else {
            invalidContent()
            focusedField = .content
            return
        }
        isPublishing = true
        let accepted = publishAction(trimmedTitle, trimmedContent) { success in
            isPublishing = false
            guard success else { return }
            onPublished?()
            if dismissAfterPublish {
                dismiss()
            }
        }
        if !accepted { isPublishing = false }
    }

    var body: some View {
#if DEBUG
        let _ = ChatSecondaryRenderingDiagnostics.announcementEditor?(ChatSecondaryAnnouncementEditorProbe(isPublishing: isPublishing, submit: publish))
#endif
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                            VStack(alignment: .leading, spacing: 5) {
                                Text(isEditing ? "编辑公告" : "发布公告")
                                    .font(.system(size: 24, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text(group.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                        }
                        .im4GlassCard(radius: 28)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("公告标题")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            TextField("公告标题", text: $draftTitle)
                                .focused($focusedField, equals: .title)
                                .font(.system(size: 16, weight: .bold))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .im4ImReadableInputText()
                                .padding(.horizontal, 14)
                                .frame(height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.white)
                                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                                )
                        }
                        .im4PlainCard(radius: 24)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("公告内容", systemImage: "text.alignleft")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Spacer()
                                Text("\(draftContent.count) 字")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .monospacedDigit()
                            }

                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $draftContent)
                                    .focused($focusedField, equals: .content)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(IMColor.ink)
                                    .im4ScrollContentBackgroundHiddenCompat()
                                    .frame(minHeight: 180)
                                    .padding(10)
                                    .background(.white)
                                if trimmedContent.isEmpty {
                                    Text("请输入公告内容，发布后成员将在群内看到最新公告")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(IMColor.muted.opacity(0.72))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }
                            }
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(focusedField == .content ? IMColor.brand.opacity(0.42) : IMColor.line, lineWidth: 1.2)
                            )
                        }
                        .im4PlainCard(radius: 24)

                        PrimaryButton(
                            title: isPublishing ? "保存中..." : (isEditing ? "保存公告" : "发布公告"),
                            systemImage: "paperplane.fill",
                            disabled: publishDisabled,
                            action: publish
                        )
                    }
                    .padding(18)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPublishing ? "保存中" : (isEditing ? "保存" : "发布")) {
                        publish()
                    }
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(publishDisabled ? IMColor.muted : IMColor.brand)
                    .disabled(publishDisabled)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                focusedField = .content
            }
        }
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

func groupAnnouncementDisplayContent(content: String?, summary: String?, groupNotice: String) -> String {
    for candidate in [content, summary, groupNotice] {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
              value != "暂无群公告" else {
            continue
        }
        return value
    }
    return ""
}

func groupAnnouncementHasVisibleContent(content: String?, summary: String?, groupNotice: String) -> Bool {
    !groupAnnouncementDisplayContent(content: content, summary: summary, groupNotice: groupNotice).isEmpty
}
