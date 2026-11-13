import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

public struct BatchForwardSelectionContent: View {
    let canForward: Bool
    let selectedCount: Int
    let onCancel: () -> Void
    let onForward: () -> Void

    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
    public var body: some View { selectionBar(canForward: canForward) }

    private func selectionBar(canForward: Bool) -> some View {
    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
        HStack(spacing: 12) {
            Button("取消", action: onCancel)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(minWidth: 68, minHeight: 44)
                .accessibilityIdentifier("batch_forward_cancel")

            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 条")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text("发送时按原会话顺序排列")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Button(action: onForward) {
                Label("转发", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(IMColor.brand))
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || !canForward)
            .opacity(canForward ? 1 : 0.45)
            .accessibilityIdentifier("batch_forward_choose_targets")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IMColor.line)
                .frame(height: 1)
        }
    }

    public init(canForward: Bool,
        selectedCount: Int,
        onCancel: @escaping () -> Void,
        onForward: @escaping () -> Void) {
        self.canForward = canForward
        self.selectedCount = selectedCount
        self.onCancel = onCancel
        self.onForward = onForward
    }
}

public struct ForwardMessageTargetContent: View {
    let input: ChatForwardInput
    let actions: ChatForwardActions
    @Environment(\.dismiss) private var dismiss
    let sourceConversationID: String
    @State private var targetSearchDraft = ""
    @State private var targetSearchDebounceTask: Task<Void, Never>?
    @State private var targetPageLimits: [BatchForwardTargetTab: Int] = [
        .friend: 20,
        .group: 20
    ]
    private let targetPageSize = 20

    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
    private var draftState: ChatForwardDraftPresentation? { input.draft }
    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END

    private var activeTab: BatchForwardTargetTab {
        draftState?.activeTargetTab ?? .friend // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    private var selectedSourceCount: Int {
        draftState?.selectedSourceCount ?? 0 // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    private var selectedTargetCount: Int {
        draftState?.selectedTargetCount ?? 0 // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    private var selectedTargetKeys: [String] {
        draftState?.selectedTargetIdentityKeysInOrder ?? [] // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    private var isSubmitting: Bool {
        guard let phase = draftState?.submissionPhase else { // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
            return false
        }
        if case .submitting = phase {
            return true
        }
        return false
    }

    private var committedBatchID: String? {
        guard let phase = draftState?.submissionPhase else { // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
            return nil
        }
        if case .committed(let batchID) = phase {
            return batchID
        }
        return nil
    }

    private var failurePresentation: (title: String, detail: String)? {
        guard let phase = draftState?.submissionPhase else { // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
            return nil
        }
        switch phase {
        case .retryableFailure(let message):
            let detail = message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                "转发未完成",
                detail.isEmpty ? "请检查选择后使用同一批次重试。" : detail
            )
        case .uncertain(let message):
            let detail = message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                "结果待确认",
                detail.isEmpty
                    ? "网络中断时服务端可能已提交；重试会复用同一批次，不会重复发送。"
                    : detail
            )
        case .idle, .submitting, .committed:
            return nil
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { targetSearchDraft },
            set: { query in
                targetSearchDraft = query
            }
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    public var body: some View { groupDependentContent(canForward: input.canForward) }

    @ViewBuilder
    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
    private func groupDependentContent(canForward: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let allFilteredTargets = input.targets
        let visibleTargets = Array(allFilteredTargets.prefix(max(targetPageSize, targetPageLimits[activeTab] ?? targetPageSize)))
        let hasMoreTargets = visibleTargets.count < allFilteredTargets.count
        // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "arrowshape.turn.up.right.fill",
                        title: "批量转发",
                        subtitle: "\(selectedSourceCount) 条消息 → \(selectedTargetCount) 个会话",
                        showsCloseButton: !isSubmitting
                    )

                    targetTabs

                    SearchField(
                        text: searchBinding,
                        placeholder: activeTab == .friend ? "搜索好友" : "搜索群聊"
                    )

                    if !selectedTargetKeys.isEmpty {
                        selectedTargetChips
                    }

                    if visibleTargets.isEmpty {
                        EmptyStateView(
                            symbol: "bubble.left.and.bubble.right",
                            title: searchBinding.wrappedValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty ? "暂无可转发会话" : "没有匹配会话",
                            subtitle: activeTab == .friend
                                ? "可选择一个或多个好友。"
                                : "可选择一个或多个群聊。"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleTargets) { candidate in
                                    targetRow(candidate)
                                }
                                if hasMoreTargets {
                                    Button("查看更多") {
                                        targetPageLimits[activeTab, default: targetPageSize]
                                            += targetPageSize
                                    }
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .accessibilityIdentifier("batch_forward_expand_targets")
                                    .accessibilityHint("每次加载最多 \(targetPageSize) 个结果")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let failurePresentation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failurePresentation.title)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.danger)
                            Text(failurePresentation.detail)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(IMColor.danger.opacity(0.08))
                        )
                        .accessibilityElement(children: .combine)
                    }

                    Button {
                        actions.submit()
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(
                                isSubmitting
                                    ? "正在转发"
                                    : (failurePresentation == nil ? "确认转发" : "使用同一批次重试")
                            )
                                .font(.system(size: 15, weight: .black))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(
                                    selectedSourceCount > 0 && selectedTargetCount > 0 && canForward
                                        ? IMColor.brand
                                        : IMColor.muted.opacity(0.45)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        isSubmitting
                            || selectedSourceCount == 0
                            || selectedTargetCount == 0
                            || !canForward
                    )
                    .accessibilityIdentifier("batch_forward_submit")
                    .accessibilityHint("消息将按原会话顺序发送")
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .im4PresentationDragIndicatorCompat(.visible)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            targetSearchDraft = draftState?.targetSearchQuery ?? "" // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
        }
        .onChange(of: targetSearchDraft) { query in
            targetSearchDebounceTask?.cancel()
            targetPageLimits[activeTab] = targetPageSize
            targetSearchDebounceTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Task.checkCancellation()
                    actions.search(query)
                } catch {
                    return
                }
            }
        }
        .onChange(of: committedBatchID) { batchID in
            if batchID != nil {
                dismiss()
            }
        }
        .onDisappear {
            targetSearchDebounceTask?.cancel()
        }
    }

    private var targetTabs: some View {
        HStack(spacing: 8) {
            targetTabButton(.friend, title: "好友", symbol: "person.fill")
            targetTabButton(.group, title: "群聊", symbol: "person.3.fill")
        }
    }

    private func targetTabButton(
        _ tab: BatchForwardTargetTab,
        title: String,
        symbol: String
    ) -> some View {
        Button {
            actions.tab(tab)
            targetPageLimits[tab] = max(
                targetPageSize,
                targetPageLimits[tab] ?? targetPageSize
            )
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(activeTab == tab ? .white : IMColor.ink)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(activeTab == tab ? IMColor.brand : .white.opacity(0.78))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
        .accessibilityIdentifier("batch_forward_tab_\(tab.rawValue)")
    }

    private var selectedTargetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedTargetKeys, id: \.self) { identityKey in
                    if let target = draftState? // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
                        .targetsByIdentity[identityKey] {
                        Button {
                            actions.remove(identityKey)
                        } label: {
                            HStack(spacing: 5) {
                                Text(target.displayName)
                                    .lineLimit(1)
                                Image(systemName: "xmark.circle.fill")
                            }
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(
                                Capsule().fill(IMColor.brand.opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityLabel("移除目标 \(target.displayName)")
                    }
                }
            }
        }
        .accessibilityIdentifier("batch_forward_selected_targets")
    }

    @ViewBuilder
    private func targetAvatar(for candidate: BatchForwardTargetCandidate) -> some View {
        if candidate.isGroup {
            ChatGroupAvatarView(
                name: candidate.target.displayName,
                seed: candidate.avatarSeed,
                size: 44,
                imageURL: candidate.avatarURL,
                avatarVersion: candidate.avatarVersion,
                avatarUpdatedAt: candidate.avatarUpdatedAt,
                imageCacheKey: input.avatarCacheKeys[candidate.identityKey] ?? ""
            )
        } else {
            ChatAvatarView(
                name: candidate.target.displayName,
                seed: candidate.avatarSeed,
                size: 44,
                imageURL: candidate.avatarURL,
                avatarVersion: candidate.avatarVersion,
                avatarUpdatedAt: candidate.avatarUpdatedAt,
                certificationReference: input.certifications[targetCertificationUID(for: candidate)]
            )
        }
    }

    private func targetRow(_ candidate: BatchForwardTargetCandidate) -> some View {
        let selected = input.selectedKeys.contains(candidate.identityKey)
        let certificationUID = targetCertificationUID(for: candidate)
        return Button {
            actions.toggle(candidate.target)
        } label: {
            HStack(spacing: 12) {
                targetAvatar(for: candidate)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.target.displayName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if !candidate.isGroup {
                        ChatCertificationPillView(
                            exactUID: certificationUID,
                            compact: true
                        )
                    }
                    Text(candidate.subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(selected ? IMColor.brand : IMColor.muted)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.84)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .certificationAccessibilityLabel(
            "\(selected ? "取消选择" : "选择") \(candidate.target.displayName)",
            reference: input.certifications[certificationUID]
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("forward_target_row_\(candidate.identityKey)")
    }

    private func targetCertificationUID(for candidate: BatchForwardTargetCandidate) -> String {
        chatForwardTargetCertificationUID(for: candidate, actor: draftState?.actorUID)
    }


    public init(input: ChatForwardInput,
        actions: ChatForwardActions,
        sourceConversationID: String) {
        self.input = input
        self.actions = actions
        self.sourceConversationID = sourceConversationID
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
