import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI

struct BatchForwardSelectionBar: View {
    @EnvironmentObject private var state: AppState
    let selectedCount: Int
    let onCancel: () -> Void
    let onForward: () -> Void
    var body: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.batchForwardBar?(self)
#endif
        state.observeChatSecondaryEntry { entry in
            state.tenantInteractionStore.observe(\.canForward) { allowed in
                BatchForwardSelectionContent(canForward: allowed, selectedCount: selectedCount,
                    onCancel: { if entry.isCurrent(state) { onCancel() } },
                    onForward: { if entry.isCurrent(state) { onForward() } })
            }
        }
    }
}

struct ForwardMessageTargetSheet: View {
    @EnvironmentObject private var state: AppState
    let sourceConversationID: String
    @State private var observedDraft: BatchForwardPresentationStore.Draft?
    private var draftState: BatchForwardState? {
        if let observedDraft, observedDraft.sourceConversationID == sourceConversationID { return observedDraft.state }
        return state.batchForwardStore.draft(for: sourceConversationID)?.state
    }
    var body: some View {
        let store = state.contactStore
        return state.observeChatSecondaryEntry { entry in
            PublisherSnapshotView(initialValue: store.groups, updates: store.groupDirectoryUpdates) { _ in
                ContactDirectoryPresentationView(store: store) {
                    state.conversationStore.observeConversationCollection({ $0.filter { $0.kind != .system }.map(\.withoutMessages) }) { conversations in
                        state.tenantInteractionStore.observe(\.canForward) { allowed in
                            assembledContent(conversations: conversations, canForward: allowed, entry: entry)
                        }
                    }
                }
            }
        }
        .onReceive(state.batchForwardStore.draftUpdates(for: sourceConversationID)) { draft in
            if draft != observedDraft { observedDraft = draft }
        }
    }
    private func assembledContent(conversations: [Conversation], canForward: Bool, entry: ChatSecondaryEntry) -> some View {
        let supportedTargets = state.batchForwardTargetCandidates(from: conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) })
        let targets = state.batchForwardVisibleTargetCandidates(from: supportedTargets, initialLimit: .max)
        let scope = draftState?.scope
        let batchID = draftState?.clientBatchID
        let intent = draftState?.boundIntentSignature
        let valid = { entry.isCurrent(state) && state.batchForwardStore.draft(for: sourceConversationID)?.state.scope == scope }
        let cacheKeys = Dictionary(uniqueKeysWithValues: targets.map { candidate in
            (candidate.identityKey, state.groupAvatarCacheKey(groupID: candidate.target.channelID, avatarURL: candidate.avatarURL,
                avatarVersion: candidate.avatarVersion, avatarUpdatedAt: candidate.avatarUpdatedAt))
        })
        let keys = Set(targets.filter { state.isBatchForwardTargetSelected($0.target) }.map(\.identityKey))
        let actions = ChatForwardActions(submit: {
            guard valid(), state.batchForwardStore.draft(for: sourceConversationID)?.state.clientBatchID == batchID,
                  state.batchForwardStore.draft(for: sourceConversationID)?.state.boundIntentSignature == intent else { return }
            state.submitBatchForward()
        },
            search: { if valid() { state.setBatchForwardTargetSearchQuery($0) } },
            tab: { if valid() { state.setBatchForwardTargetTab($0) } },
            remove: { if valid() { state.removeBatchForwardTarget(identityKey: $0) } },
            toggle: { if valid() { state.toggleBatchForwardTarget($0) } })
        let ids = Set(targets.map { chatForwardTargetCertificationUID(for: $0, actor: draftState?.scope.actorUID) })
        let certifications = Dictionary(uniqueKeysWithValues: ids.compactMap { uid in
            state.certificationPillSource.reference(forExactUID: uid).map { (uid, $0) }
        })
        let input = ChatForwardInput(draft: draftState.map { ChatForwardDraftPresentation(actorUID: $0.scope.actorUID, activeTargetTab: $0.activeTargetTab, selectedSourceCount: $0.selectedSourceIDSet.count, selectedTargetCount: $0.selectedTargets.count, selectedTargetIdentityKeysInOrder: $0.selectedTargetIdentityKeysInOrder, targetSearchQuery: $0.targetSearchQuery, submissionPhase: $0.submissionPhase, targetsByIdentity: $0.targetsByIdentity) }, targets: targets, canForward: canForward,
            selectedKeys: keys, avatarCacheKeys: cacheKeys, certifications: certifications.mapValues(\.chatFeatureReference))
#if DEBUG
        ChatSecondaryRenderingDiagnostics.forward?(input, actions)
#endif
        return ForwardMessageTargetContent(input: input, actions: actions, sourceConversationID: sourceConversationID)
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
