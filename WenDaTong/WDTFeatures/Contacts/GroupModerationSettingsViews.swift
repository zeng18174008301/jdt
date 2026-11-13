import IM4Features
import SwiftUI
import UIKit

struct GroupMuteAllSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var selectedMode: GroupMuteMode
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var inlineMessage: String?

    init(group: GroupInfo) {
        self.group = group
        let defaultStart = group.allMuteStart ?? Date()
        let defaultEnd = group.allMuteEnd ?? Calendar.current.date(byAdding: .hour, value: 2, to: defaultStart) ?? defaultStart.addingTimeInterval(7200)
        let mode = group.allMuteMode
            ?? (group.allMuted ? (group.allMuteStart == nil && group.allMuteEnd == nil ? .always : .scheduled) : .off)
        _selectedMode = State(initialValue: mode == .off ? .always : mode)
        _startAt = State(initialValue: defaultStart)
        _endAt = State(initialValue: defaultEnd)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var normalizedEndAt: Date {
        let calendar = Calendar.current
        let baseDay = calendar.startOfDay(for: startAt)
        let endTime = calendar.dateComponents([.hour, .minute], from: endAt)
        var components = calendar.dateComponents([.year, .month, .day], from: baseDay)
        components.hour = endTime.hour
        components.minute = endTime.minute
        let calculated = calendar.date(from: components) ?? endAt
        if calculated <= startAt {
            return calendar.date(byAdding: .day, value: 1, to: calculated) ?? calculated
        }
        return calculated
    }

    private var endsOnNextDay: Bool {
        !Calendar.current.isDate(startAt, inSameDayAs: normalizedEndAt)
    }

    private var schedulePreview: String {
        var previewGroup = currentGroup
        previewGroup.allMuted = true
        previewGroup.allMuteMode = .scheduled
        previewGroup.allMuteActive = nil
        previewGroup.allMuteServerTime = Date()
        previewGroup.allMuteStart = startAt
        previewGroup.allMuteEnd = normalizedEndAt
        return previewGroup.allMuteTimeRangeText()
    }

    private var canCloseMute: Bool {
        currentGroup.allMuted
            || currentGroup.allMuteMode != nil && currentGroup.allMuteMode != .off
            || currentGroup.allMuteRepairRequired
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) {
            // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
            let groupID = currentGroup.id.trimmingCharacters(in: .whitespacesAndNewlines)
            PublisherSnapshotView(
                initialValue: state.groupModerationStore.settingsSnapshot(for: groupID),
                updates: state.groupModerationStore.settingsPublisher(for: groupID)
            ) { snapshot in
                groupContent(snapshot)
            }
            // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    private func groupContent(_ snapshot: GroupModerationStore.SettingsSnapshot) -> some View {
        GroupMuteAllContent(
            selectedMode: $selectedMode, startAt: $startAt, endAt: $endAt,
            status: currentGroup.allMuteStatusText(), endsOnNextDay: endsOnNextDay,
            schedulePreview: schedulePreview, requiresRepair: currentGroup.allMuteRepairRequired,
            inlineMessage: inlineMessage ?? snapshot.errorMessage, canCloseMute: canCloseMute,
            isSubmitting: snapshot.isMutating, onModeChange: { inlineMessage = nil }, onSubmit: submit
        )
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

    private func submit(mode: GroupMuteMode) {
        inlineMessage = nil
        let accepted = state.configureGroupMute(
            currentGroup.id,
            mode: mode,
            startAt: mode == .scheduled ? startAt : nil,
            endAt: mode == .scheduled ? normalizedEndAt : nil
        ) { succeeded in
            if succeeded {
                dismiss()
            } else {
                inlineMessage = state.groupMuteErrorMessage(for: currentGroup.id)
                    ?? state.toast
                    ?? "全员禁言设置失败，请重试"
            }
        }
        if !accepted {
            inlineMessage = state.toast ?? "全员禁言设置不合法"
        }
    }
}

struct GroupJoinApprovalSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        GroupJoinApprovalContent(isOn: Binding(
            get: { currentGroup.inviteConfirmRequired },
            set: { newValue in
                if newValue != currentGroup.inviteConfirmRequired {
                    state.toggleGroupInviteApproval(currentGroup.id, enabled: newValue)
                }
            }
        ), onClose: { dismiss() })
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
        // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
        .onReceive(state.forcedAppPolicyAuthStore.updates(\.prompt)) { prompt in
            if prompt != nil { dismiss() }
        }
        // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END
    }
}

struct GroupHistoryVisibilitySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showEnableConfirm = false
    let group: GroupInfo

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        state.canManageGroup(currentGroup)
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        GroupHistoryVisibilityContent(isOn: Binding(
            get: { currentGroup.historyVisible },
            set: { newValue in
                guard canManage else { return }
                guard newValue != currentGroup.historyVisible else { return }
                if newValue {
                    showEnableConfirm = true
                } else {
                    state.toggleGroupHistoryVisibility(currentGroup.id, enabled: false)
                }
            }
        ), showEnableConfirm: $showEnableConfirm, canManage: canManage,
            onConfirmEnable: { state.toggleGroupHistoryVisibility(currentGroup.id, enabled: true) }, onClose: { dismiss() })
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
    }
}

struct GroupMuteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var selectedMuted: Bool

    init(group: GroupInfo) {
        self.group = group
        _selectedMuted = State(initialValue: group.muted)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    private var currentMuted: Bool {
        GroupNotificationMuteProjection.isMuted(group: currentGroup, conversation: nil)
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        GroupMuteContent(isOn: Binding(
            get: { selectedMuted },
            set: { newValue in
                if newValue != selectedMuted {
                    selectedMuted = newValue
                    state.toggleGroupMuted(currentGroup.id)
                }
            }
        ), onClose: { dismiss() })
        .onAppear {
            selectedMuted = currentMuted
        }
        .onChangeCompat(of: currentMuted) { _, newValue in
            selectedMuted = newValue
        }
    }
}

typealias GroupSheetActionButton = IM4Features.GroupSheetActionButton

private typealias GroupToggleRow = IM4Features.GroupToggleRow
