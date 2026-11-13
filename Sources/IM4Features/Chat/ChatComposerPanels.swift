import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

public enum ChatExpressionTab: String, CaseIterable, Identifiable {
    case emoji
    case stickers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .emoji: return "Emoji"
        case .stickers: return "表情包"
        }
    }
}

// WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
public struct ChatStickerPanelItem: Identifiable {
    public let item: StickerLibraryItem
    public let isDeleting: Bool
    public let isSorting: Bool
    public var id: String { item.id }

    public init(item: StickerLibraryItem,
        isDeleting: Bool,
        isSorting: Bool) {
        self.item = item
        self.isDeleting = isDeleting
        self.isSorting = isSorting
    }
}

public struct ChatStickerPanelInput {
    public let items: [ChatStickerPanelItem]
    public let isManifestRefreshing: Bool
    public let manifestErrorMessage: String?

    public init(items: [ChatStickerPanelItem],
        isManifestRefreshing: Bool,
        manifestErrorMessage: String? = nil) {
        self.items = items
        self.isManifestRefreshing = isManifestRefreshing
        self.manifestErrorMessage = manifestErrorMessage
    }
}

public struct ChatExpressionPanelContent: View {
    let input: ChatStickerPanelInput
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
    let deleteSticker: @MainActor (StickerLibraryItem) -> Int
    let moveSticker: @MainActor (StickerLibraryItem, Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isManagingStickers = false
    @State private var pendingStickerDeletion: StickerLibraryItem?
    @State private var showStickerDeleteConfirmation = false

    private let emojiColumns = [GridItem(.adaptive(minimum: 44, maximum: 58), spacing: 8)]
    private let stickerColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private let contentHeight: CGFloat = 268
    private let panelHeight: CGFloat = 320

    private var hasManageableStickers: Bool {
        input.items.contains { !$0.item.isLocalUploadPlaceholder }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar

            ZStack(alignment: .top) {
                emojiGrid
                    .opacity(selectedTab == .emoji ? 1 : 0)
                    .offset(x: selectedTab == .emoji ? 0 : -18)
                    .allowsHitTesting(selectedTab == .emoji)

                stickerLibrary
                    .opacity(selectedTab == .stickers ? 1 : 0)
                    .offset(x: selectedTab == .stickers ? 0 : 18)
                    .allowsHitTesting(selectedTab == .stickers)
            }
            .frame(height: contentHeight)
            .clipped()
        }
        .padding(.top, 4)
        .frame(height: panelHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: selectedTab)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: isManagingStickers)
        .confirmationDialog(
            "删除这个表情？",
            isPresented: $showStickerDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let item = pendingStickerDeletion else { return }
                let remainingCount = deleteSticker(item)
                pendingStickerDeletion = nil
                if remainingCount <= 1 {
                    isManagingStickers = false
                }
            }
            Button("取消", role: .cancel) {
                pendingStickerDeletion = nil
            }
        } message: {
            Text("删除后不影响历史消息中的缩略图和摘要展示。")
        }
        .im4OnChangeCompat(of: selectedTab) { _, tab in
            if tab == .emoji {
                isManagingStickers = false
            }
        }
        .task(id: selectedTab) {
            guard selectedTab == .stickers else { return }
            await prepareStickers()
        }
        .accessibilityIdentifier("chat_expression_panel")
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ChatExpressionTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(selectedTab == tab ? IMColor.ink : IMColor.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? .white : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(selectedTab == tab ? "已选择" : "")
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    .accessibilityIdentifier("chat_expression_tab_\(tab.rawValue)")
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(im4Hex: 0xF1F4FB)))

            Button {
                refreshStickers()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(selectedTab != .stickers)
            .opacity(selectedTab == .stickers ? 1 : 0.36)
            .accessibilityLabel("刷新表情包")
            .accessibilityHint(selectedTab == .stickers ? "重新同步我的表情包" : "切换到表情包后可用")
            .accessibilityIdentifier("chat_sticker_refresh_button")
        }
    }

    private var emojiGrid: some View {
        Group {
            if let unicodePicker {
                unicodePicker
                    .accessibilityIdentifier("chat_unicode_emoji_picker")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: emojiColumns, spacing: 8) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button {
                                insertEmoji(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 26))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(emoji))
                            .accessibilityHint("插入此 Emoji")
                            .accessibilityIdentifier("chat_legacy_emoji_\(emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_"))")
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var stickerLibrary: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                myStickersSection
            }
            .padding(.bottom, 4)
        }
    }

    private var myStickersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("我的表情")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    if input.items.contains(where: { $0.item.isProcessing }) {
                        Text("处理中")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IMColor.warning)
                    }
                }
                if input.isManifestRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(IMColor.brand)
                }
                Spacer()
                if hasManageableStickers {
                    Button {
                        isManagingStickers.toggle()
                    } label: {
                        Label(isManagingStickers ? "完成" : "管理", systemImage: isManagingStickers ? "checkmark" : "slider.horizontal.3")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(isManagingStickers ? IMColor.brand : IMColor.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(im4Hex: 0xF1F4FB)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_sticker_manage_button")
                }
                Button {
                    addStickerPhoto()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.brand))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat_sticker_add_button")
            }

            if let message = input.manifestErrorMessage, !message.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IMColor.warning)
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.warning.opacity(0.10)))
            }

            if input.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.brand)
                    Text(input.isManifestRefreshing ? "正在同步我的表情" : "暂无我的表情")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(im4Hex: 0xF7F8FC)))
            } else {
                LazyVGrid(columns: stickerColumns, spacing: 12) {
                    ForEach(Array(input.items.enumerated()), id: \.element.id) { index, row in
                        let item = row.item
                        StickerLibraryCell(
                            item: item,
                            thumbnailURL: stickerThumbnailURL(item),
                            isManaging: isManagingStickers,
                            isDeleting: row.isDeleting,
                            isSorting: row.isSorting,
                            canMoveUp: index > 0,
                            canMoveDown: index < input.items.count - 1,
                            onTap: {
                                if isManagingStickers, !item.isLocalUploadPlaceholder {
                                    return
                                } else if item.isLocalUploadPlaceholder, item.isFailed {
                                    retrySticker(item)
                                } else {
                                    sendSticker(item)
                                }
                            },
                            onEnterManage: {
                                if !item.isLocalUploadPlaceholder {
                                    isManagingStickers = true
                                }
                            },
                            onRetry: { retrySticker(item) },
                            onDelete: {
                                if item.isLocalUploadPlaceholder {
                                    _ = deleteSticker(item)
                                } else {
                                    pendingStickerDeletion = item
                                    showStickerDeleteConfirmation = true
                                }
                            },
                            onMoveUp: { moveSticker(item, -1) },
                            onMoveDown: { moveSticker(item, 1) }
                        )
                    }
                }
            }
        }
    }

    public init(input: ChatStickerPanelInput,
        selectedTab: Binding<ChatExpressionTab>,
        emojis: [String],
        insertEmoji: @escaping (String) -> Void,
        addStickerPhoto: @escaping () -> Void,
        sendSticker: @escaping (StickerLibraryItem) -> Void,
        unicodePicker: AnyView? = nil,
        prepareStickers: @escaping @MainActor () async -> Void,
        refreshStickers: @escaping @MainActor () -> Void,
        stickerThumbnailURL: @escaping @MainActor (StickerLibraryItem) -> String,
        retrySticker: @escaping @MainActor (StickerLibraryItem) -> Void,
        deleteSticker: @escaping @MainActor (StickerLibraryItem) -> Int,
        moveSticker: @escaping @MainActor (StickerLibraryItem, Int) -> Void) {
        self.input = input
        self._selectedTab = selectedTab
        self.emojis = emojis
        self.insertEmoji = insertEmoji
        self.addStickerPhoto = addStickerPhoto
        self.sendSticker = sendSticker
        self.unicodePicker = unicodePicker
        self.prepareStickers = prepareStickers
        self.refreshStickers = refreshStickers
        self.stickerThumbnailURL = stickerThumbnailURL
        self.retrySticker = retrySticker
        self.deleteSticker = deleteSticker
        self.moveSticker = moveSticker
    }
}
// WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END

private struct StickerLibraryCell: View {
    let item: StickerLibraryItem
    let thumbnailURL: String
    let isManaging: Bool
    let isDeleting: Bool
    let isSorting: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onTap: () -> Void
    let onEnterManage: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        ZStack {
            Button(action: onTap) {
                stickerTile
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    onEnterManage()
                }
            )

            if isManaging, !item.isLocalUploadPlaceholder {
                manageOverlay
            }

            if item.isLocalUploadPlaceholder, item.isFailed {
                failedUploadOverlay
            }

            if isDeleting || isSorting {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.70))
                    .frame(width: 64, height: 64)
                ProgressView()
                    .scaleEffect(0.72)
                    .tint(IMColor.brand)
            }
        }
        .frame(height: 74)
        .accessibilityIdentifier("chat_sticker_cell_\(item.id)")
    }

    private var stickerTile: some View {
        StickerThumbnail(item: item, thumbnailURL: thumbnailURL)
            .frame(width: 64, height: 64)
            .scaleEffect(isManaging && !item.isLocalUploadPlaceholder ? 0.94 : 1)
            .overlay {
                if item.isLocalUploadPlaceholder, let title = item.uploadTileTitle {
                    StickerUploadTileOverlay(title: title, subtitle: item.uploadSubtitle, isFailed: item.isFailed)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !item.isActive && !item.isLocalUploadPlaceholder {
                    Text(item.statusTitle)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(item.isFailed ? IMColor.danger : IMColor.warning))
                        .offset(x: 6, y: -6)
                }
            }
    }

    private var manageOverlay: some View {
        ZStack {
            VStack {
                HStack {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20, weight: .black))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, IMColor.danger)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    Spacer()
                }
                Spacer()
            }

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .black))
                            .frame(width: 24, height: 20)
                            .background(Capsule().fill(.white.opacity(0.94)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp || isSorting || isDeleting)
                    .opacity(canMoveUp ? 1 : 0.36)

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .black))
                            .frame(width: 24, height: 20)
                            .background(Capsule().fill(.white.opacity(0.94)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown || isSorting || isDeleting)
                    .opacity(canMoveDown ? 1 : 0.36)
                }
                .foregroundStyle(IMColor.ink)
            }
        }
        .frame(width: 72, height: 72)
    }

    private var failedUploadOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(.white.opacity(0.94)))
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(.white.opacity(0.94)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(IMColor.danger)
            }
        }
        .frame(width: 72, height: 72)
    }
}

private struct StickerUploadTileOverlay: View {
    let title: String
    let subtitle: String?
    let isFailed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(isFailed ? 0.58 : 0.42))
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: title.count <= 3 ? 15 : 12, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let subtitle, subtitle != title {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct StickerThumbnail: View {
    let item: StickerLibraryItem
    let thumbnailURL: String

    // WDT_IOS1_IMAGE_BUDGET_20261023: sticker grid requests a thumbnail, not a full-size image.
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(im4Hex: 0xF7F8FC))
            if thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: item.isLocalUploadPlaceholder ? "photo.badge.plus" : (item.source == .mine ? "face.smiling" : "sparkles"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            } else {
                ChatRemoteImageView(urlString: thumbnailURL, cacheKey: item.stableThumbnailCacheKey, contentMode: .fit, maxPixelSize: 256) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(im4Hex: 0xE6EAF3), lineWidth: 1))
    }
}

public struct MentionSuggestionPanel: View {
    @Environment(\.chatCertificationRendering) private var certificationSource

    let suggestions: [IMUser]
    var showsMentionAll = false
    let hasQuery: Bool
    var isLoading = false
    let onSelect: (IMUser) -> Void
    var onSelectAll: () -> Void = {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.brand)
                Text("选择提及成员")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
                Spacer()
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IMColor.brand)
                    Text("正在加载群成员")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.72)))
            } else if suggestions.isEmpty && !showsMentionAll {
                Text(hasQuery ? "没有匹配成员" : "暂无可提及成员")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.72)))
            } else {
                ScrollView(.vertical, showsIndicators: suggestions.count + (showsMentionAll ? 1 : 0) > 4) {
                    LazyVStack(spacing: 7) {
                        if showsMentionAll {
                            Button(action: onSelectAll) {
                                HStack(spacing: 10) {
                                    Image(systemName: "megaphone.fill")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(IMColor.warning))
                                    Text("@所有人")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.warning.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.warning.opacity(0.24), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("提及所有人")
                        }
                        ForEach(suggestions) { user in
                            let displayName = chatProjectedMemberName(user)
                            Button {
                                onSelect(user)
                            } label: {
                                HStack(spacing: 10) {
                                    ChatAvatarView(name: displayName, seed: user.avatarSeed, size: 34, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: certificationSource?.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                                    Text(displayName)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    ChatCertificationPillView(
                                        exactUID: user.id,
                                        compact: true
                                    )
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .certificationAccessibilityLabel(
                                "提及 \(displayName)",
                                reference: certificationSource?.reference(forExactUID: user.id)
                            ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(IMColor.brand.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.brand.opacity(0.12), lineWidth: 1))
	        )
	    }


    public init(suggestions: [IMUser],
        showsMentionAll: Bool = false,
        hasQuery: Bool,
        isLoading: Bool = false,
        onSelect: @escaping (IMUser) -> Void,
        onSelectAll: @escaping () -> Void = {}) {
        self.suggestions = suggestions
        self.showsMentionAll = showsMentionAll
        self.hasQuery = hasQuery
        self.isLoading = isLoading
        self.onSelect = onSelect
        self.onSelectAll = onSelectAll
    }
}

