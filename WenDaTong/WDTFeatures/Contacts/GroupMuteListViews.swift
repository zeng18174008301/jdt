import IM4Features
import SwiftUI
import UIKit

struct GroupMuteListSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var showAddMember = false
    @State private var pendingRemoval: GroupMuteListItem?

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        accessMode == .manage
    }

    private var accessMode: GroupMuteListAccessMode {
        GroupMuteListAccessMode(canManage: state.canManageGroupMuteList(currentGroup))
    }

    private func displayName(for item: GroupMuteListItem) -> String {
        state.remarkPreferredDisplayName(
            identifiers: [item.targetUID, item.targetUserID, item.targetUsername],
            candidates: [item.targetNickname],
            fallback: item.targetDisplayName
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) {
            // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_BEGIN
            ContactDirectoryPresentationView(store: state.contactStore) {
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
                let groupID = currentGroup.id.trimmingCharacters(in: .whitespacesAndNewlines)
                PublisherSnapshotView(
                    initialValue: state.groupModerationStore.listSnapshot(for: groupID),
                    updates: state.groupModerationStore.listPublisher(for: groupID)
                ) { snapshot in
                    groupContent(snapshot)
                }
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    private func groupContent(_ snapshot: GroupModerationStore.ListSnapshot) -> some View {
        let items = state.projectedGroupMuteListItems(snapshot.items ?? [])
        return GroupMuteListContent(
            canManage: canManage,
            canAddMember: canManage && !state.groupMuteListCandidateMembers(for: currentGroup.id, mutedItems: items).isEmpty,
            isLoading: snapshot.isLoading, isEmpty: items.isEmpty, errorMessage: snapshot.errorMessage,
            onAddMember: { showAddMember = true },
            onRetry: { state.loadGroupMuteList(groupID: currentGroup.id, force: true) }
        ) {
            ForEach(items) { item in
                GroupMuteListRow(
                    item: item,
                    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110
                    displayName: displayName(for: item),
                    isMutating: snapshot.isMutating(targetUID: item.targetUID)
                ) {
                    pendingRemoval = item
                }
            }
        }
        .sheet(isPresented: $showAddMember) {
            GroupMuteMemberPickerSheet(groupID: currentGroup.id)
                .presentationDetentsCompat([.medium, .large])
                .presentationDragIndicatorCompat(.visible)
        }
        .alert(item: $pendingRemoval) { item in
            Alert(
                title: Text("解除禁言？"),
                message: Text("确认将 \(displayName(for: item)) 从禁言名单移除。"),
                primaryButton: .destructive(Text("解除禁言")) {
                    Task {
                        await state.removeGroupMuteListMember(groupID: currentGroup.id, targetUID: item.targetUID)
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear {
            guard accessMode.loadsRemoteList else { return }
            state.loadGroupDetailIfNeeded(groupID: currentGroup.id, force: true)
            state.loadGroupMuteList(groupID: currentGroup.id, force: true)
            state.loadNextGroupMembersPageIfNeeded(groupID: currentGroup.id)
        }
        .accessibilityIdentifier("group_mute_list_sheet")
    }
    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
}

private struct GroupMuteListRow: View {
    @EnvironmentObject private var state: AppState

    let item: GroupMuteListItem
    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110: resolve the live name once in the list and pass it to the row.
    let displayName: String
    let isMutating: Bool
    let onRemove: () -> Void

    var body: some View {
        GroupMuteListRowContent(
            targetUID: item.targetUID, displayID: item.targetDisplayID, displayName: displayName,
            reasonText: item.reasonText, operatorText: item.operatorText, createdAtText: item.createdAtText,
            isMutating: isMutating, avatar: {
                AvatarView(name: displayName, seed: 0xF59E0B, size: 46, imageURL: item.targetAvatarURL,
                           certificationReference: state.certificationPillSource.reference(forExactUID: item.targetUID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: item.targetUID, compact: true) },
            onCopyUserID: state.copyUserID, onRemove: onRemove
        )
    }
}

private struct GroupMuteMemberPickerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    @State private var query = ""
    @State private var selectedUser: IMUser?
    @State private var reason = ""
    @State private var isSubmitting = false

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    private func candidates(mutedItems: [GroupMuteListItem]) -> [IMUser] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.groupMuteListCandidateMembers(for: groupID, mutedItems: mutedItems).filter { user in
            trimmedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: trimmedQuery
            )
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

    private var selectedTargetUID: String {
        guard let selectedUser else { return "" }
        let candidates = [selectedUser.id, selectedUser.userID, selectedUser.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { !$0.isEmpty } ?? ""
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_BEGIN
    var body: some View {
        ContactDirectoryPresentationView(store: state.contactStore) { directoryContent }
    }
    // WDT_IOS1_REFACTOR_MEMBER_DIRECTORY_OBSERVATION_20261110_END

    private var directoryContent: some View {
        GroupSnapshotView(store: state.contactStore, groupID: groupID) {
            // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
            let key = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            PublisherSnapshotView(
                initialValue: state.groupModerationStore.listSnapshot(for: key),
                updates: state.groupModerationStore.listPublisher(for: key)
            ) { snapshot in
                groupDependentContent(candidates: candidates(mutedItems: snapshot.items ?? []))
            }
            // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    private func groupDependentContent(candidates: [IMUser]) -> some View { // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110
        GroupMuteMemberPickerContent(query: $query, reason: $reason, isEmpty: candidates.isEmpty,
            hasSelection: selectedUser != nil, canSubmit: !selectedTargetUID.isEmpty && !isSubmitting,
            onSubmit: submit) {
            ForEach(candidates) { user in
                let displayName = state.remarkPreferredDisplayName(for: user)
                GroupMemberSelectionRowContent(
                    displayName: displayName,
                    displayID: user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.id : user.userID,
                    isSelected: selectedUser?.id == user.id,
                    avatar: {
                        AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    }, certification: {
                        CertificationPillView(
                            exactUID: user.id,
                            compact: true
                        )
                    },
                    onCopyUserID: state.copyUserID, onSelect: { selectedUser = user }
                )
            }
        }
        .onAppear {
            state.loadNextGroupMembersPageIfNeeded(groupID: groupID)
        }
    }

    private func submit() {
        guard !isSubmitting, !selectedTargetUID.isEmpty else { return }
        isSubmitting = true
        Task {
            let ok = await state.addGroupMuteListMember(groupID: groupID, targetUID: selectedTargetUID, reason: reason)
            isSubmitting = false
            if ok {
                dismiss()
            }
        }
    }
}
