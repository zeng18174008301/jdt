import IM4Features
import Combine // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110
import SwiftUI
import UIKit
import QuickLook
import AVFoundation

struct RTCEntryView: View {
    @EnvironmentObject private var state: AppState
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
    @EnvironmentObject private var callStore: CallStore
    @State private var requestedCallKind: RTCCallActionKind?
    @State private var selectedCallRecord: CallRecord?
    @State private var pendingCallTask: Task<Void, Never>?
    @State private var pendingCallGeneration = 0

    private var isCallSessionBusy: Bool {
        callStore.isStartingVoiceCall
            || callStore.isStartingVideoCall
            || callStore.incomingVoiceCall != nil
            || callStore.activeVoiceCall != nil
    }

    private var newVoiceCallUnavailableReason: String? {
        isCallSessionBusy ? "请先处理当前通话" : nil
    }

    private var newVideoCallUnavailableReason: String? {
        isCallSessionBusy ? "请先处理当前通话" : nil
    }

    var body: some View {
        RTCCallHistoryContent(calls: callStore.calls, voiceUnavailable: newVoiceCallUnavailableReason,
            videoUnavailable: newVideoCallUnavailableReason, incomingCall: {
                if let call = callStore.incomingVoiceCall { RTCIncomingCallCard(call: call) }
            }, callRow: { RTCCallRecordRow(call: $0) }, onRequestVoice: {
                guard state.guardCallLicenseForAction(.voice) else { return }
                requestedCallKind = .voice
            }, onRequestVideo: {
                guard state.guardCallLicenseForAction(.video) else { return }
                requestedCallKind = .video
            }, onSelectCall: { selectedCallRecord = $0 })
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $requestedCallKind) { requestedKind in
            RTCCallContactPickerSheet(preferredKind: requestedKind) { user, selectedKind in
                requestedCallKind = nil
                startCallAfterSheetDismissal(user, kind: selectedKind)
            }
            .environmentObject(state)
            .presentationDetentsCompat([.medium, .large])
            .presentationDragIndicatorCompat(.visible)
        }
        .sheet(item: $selectedCallRecord) { call in
            // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_BEGIN
            let store = state.contactStore
            PublisherSnapshotView(
                initialValue: store.contacts,
                updates: store.$contacts.removeDuplicates().eraseToAnyPublisher()
            ) { contacts in
                callRecordDetails(for: call, contacts: contacts)
            }
            // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_END
            .presentationDetentsCompat([.medium, .large])
            .presentationDragIndicatorCompat(.visible)
        }
        .onDisappear {
            cancelPendingCallTask()
        }
        .onChangeCompat(of: isCallSessionBusy) { _, isBusy in
            if isBusy {
                cancelPendingCallTask()
            }
        }
    }

    private func startCallAfterSheetDismissal(_ user: IMUser, kind: RTCCallActionKind) {
        scheduleCallAfterSheetDismissal(user, kind: kind)
    }

    private func startVoiceCallAfterSheetDismissal(_ user: IMUser) {
        scheduleCallAfterSheetDismissal(user, kind: .voice)
    }

    private func startVideoCallAfterSheetDismissal(_ user: IMUser) {
        scheduleCallAfterSheetDismissal(user, kind: .video)
    }

    private func scheduleCallAfterSheetDismissal(_ user: IMUser, kind: RTCCallActionKind) {
        let media: RTCCapabilityMedia = kind == .voice ? .voice : .video
        guard state.guardCallLicenseForAction(media) else { return }
        let licenseGeneration = state.callLicenseActionGeneration(for: media)
        pendingCallTask?.cancel()
        pendingCallGeneration += 1
        let generation = pendingCallGeneration
        pendingCallTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 360_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, pendingCallGeneration == generation else { return }
            defer {
                if pendingCallGeneration == generation {
                    pendingCallTask = nil
                }
            }
            guard state.callLicenseActionGeneration(for: media) == licenseGeneration,
                  state.guardCallLicenseForAction(media) else { return }
            if let reason = callUnavailableReason(kind: kind, user: user) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(reason)
                return
            }
            switch kind {
            case .voice:
                state.startOutgoingVoiceCall(to: user)
            case .video:
                state.startOutgoingVideoCall(to: user)
            }
        }
    }

    private func cancelPendingCallTask() {
        pendingCallGeneration += 1
        pendingCallTask?.cancel()
        pendingCallTask = nil
    }

    private func callUnavailableReason(kind: RTCCallActionKind, user: IMUser) -> String? {
        switch kind {
        case .voice:
            return newVoiceCallUnavailableReason ?? state.voiceCallUnavailableReason(for: user)
        case .video:
            return newVideoCallUnavailableReason ?? state.videoCallUnavailableReason(for: user)
        }
    }

    // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_BEGIN
    private func callRecordDetails(for call: CallRecord, contacts: [IMUser]) -> some View {
        let peer = peerUser(for: call, contacts: contacts)
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
        let store = state.contactStore
        let identities = Set(state.userIdentityCandidates(for: peer))
        return PublisherSnapshotView(
            // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
            initialValue: store.callRelationshipSnapshot(matching: identities),
            updates: store.callRelationshipUpdates(matching: identities)
        ) { _ in
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
            state.fileStore.observeUploadConfiguration(\.callLicense) { _ in
                RTCCallRecordDetailSheet(
                    call: call,
                    peer: peer,
                    canStartVoiceCall: call.direction != .system && state.canStartVoiceCall(with: peer),
                    voiceUnavailableReason: call.direction == .system ? "系统记录不可拨打" : state.voiceCallUnavailableReason(for: peer),
                    canStartVideoCall: call.direction != .system && state.videoCallEntryUnavailableReason(for: peer) == nil,
                    videoUnavailableReason: call.direction == .system ? "系统记录不可拨打" : state.videoCallUnavailableReason(for: peer),
                    onVoiceDial: {
                        guard state.guardCallLicenseForAction(.voice) else { return }
                        selectedCallRecord = nil
                        startVoiceCallAfterSheetDismissal(peer)
                    },
                    onVideoDial: {
                        guard state.guardCallLicenseForAction(.video) else { return }
                        selectedCallRecord = nil
                        startVideoCallAfterSheetDismissal(peer)
                    }
                )
            }
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END
        }
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END
    }

    private func peerUser(for call: CallRecord, contacts: [IMUser]) -> IMUser {
        // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_END
        let identifiers = [call.peerID, call.peerUserID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let contact = contacts.first(where: { contact in
            let contactIDs = [contact.id, contact.userID, contact.username]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return !Set(contactIDs).isDisjoint(with: identifiers)
        }) {
            return callPeerUser(contact, applying: call)
        }
        if !call.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let contact = contacts.first(where: { $0.name == call.title }) {
            return callPeerUser(contact, applying: call)
        }
        let fallbackID = identifiers.first ?? call.title
        return IMUser(
            id: fallbackID.isEmpty ? "unknown_voice_peer" : fallbackID,
            userID: call.peerUserID,
            name: call.title.isEmpty ? "语音联系人" : call.title,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: state.currentEnterprise.name,
            avatarSeed: UInt(bitPattern: fallbackID.hashValue),
            avatarURL: call.peerAvatarURL,
            avatarVersion: call.peerAvatarVersion,
            avatarUpdatedAt: call.peerAvatarUpdatedAt,
            badges: []
        )
    }

    private func callPeerUser(_ user: IMUser, applying call: CallRecord) -> IMUser {
        let recordAvatar = call.peerAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordVersion = call.peerAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordUpdatedAt = call.peerAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        return IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: recordAvatar.isEmpty ? user.avatarURL : recordAvatar,
            avatarVersion: recordVersion.isEmpty ? user.avatarVersion : recordVersion,
            avatarUpdatedAt: recordUpdatedAt.isEmpty ? user.avatarUpdatedAt : recordUpdatedAt,
            badges: user.badges
        )
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110: call action labels live beside the shared call record row.
private struct RTCCallRecordDetailSheet: View {
    @EnvironmentObject private var state: AppState

    @Environment(\.dismiss) private var dismiss
    let call: CallRecord
    let peer: IMUser
    let canStartVoiceCall: Bool
    let voiceUnavailableReason: String?
    let canStartVideoCall: Bool
    let videoUnavailableReason: String?
    let onVoiceDial: () -> Void
    let onVideoDial: () -> Void

    private var peerUserIDText: String {
        let value = peer.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? peer.id : value
    }

    private var certificationUID: String {
        call.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var callTypeText: String {
        let type = call.callType.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = type.isEmpty ? "语音通话" : type
        let kind = base.hasPrefix("视频") ? "视频" : "语音"
        switch call.direction {
        case .outgoing:
            return "\(kind)呼出"
        case .incoming:
            return "\(kind)来电"
        case .system:
            return base
        }
    }

    private var startedAtText: String {
        guard let startedAt = call.startedAt else { return "未记录" }
        return Self.dateFormatter.string(from: startedAt)
    }

    private var endedAtText: String {
        if let endedAt = call.endedAt {
            return Self.dateFormatter.string(from: endedAt)
        }
        return isTerminalStatus ? "未记录" : "进行中"
    }

    private var durationText: String {
        let seconds = call.durationSeconds ?? inferredDurationSeconds
        guard let seconds else {
            return isTerminalStatus ? "未记录" : "进行中"
        }
        return RTCCallRecordTimeProjection.durationText(seconds: seconds) // WDT_IOS1_CALL_DURATION_20261023
    }

    private var inferredDurationSeconds: TimeInterval? {
        guard let startedAt = call.startedAt, let endedAt = call.endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    private var isTerminalStatus: Bool {
        ["已结束", "已取消", "已拒绝", "已拒接", "未接通", "忙线"].contains(call.status)
            || call.status.contains("结束")
            || call.status.contains("取消")
            || call.status.contains("拒")
            || call.status.contains("未")
    }

    var body: some View {
        RTCCallRecordDetailContent(peerName: peer.displayName, peerUserIDText: peerUserIDText, status: call.status,
            callTypeText: callTypeText, startedAtText: startedAtText, endedAtText: endedAtText, durationText: durationText,
            canStartVoiceCall: canStartVoiceCall, voiceUnavailableReason: voiceUnavailableReason,
            canStartVideoCall: canStartVideoCall, videoUnavailableReason: videoUnavailableReason,
            avatar: {
                AvatarView(name: peer.displayName, seed: peer.avatarSeed, size: 54, imageURL: peer.displayAvatarURL, avatarVersion: peer.avatarVersion, avatarUpdatedAt: peer.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: certificationUID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, certification: { CertificationPillView(exactUID: certificationUID, compact: true) },
            onVoiceDial: onVoiceDial, onVideoDial: onVideoDial)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter
    }()

    // WDT_IOS1_CALL_DURATION_20261023: duration formatting is shared with validated history projection.

}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
private struct RTCCallContactPickerSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let preferredKind: RTCCallActionKind
    let onSelect: (IMUser, RTCCallActionKind) -> Void

    private var currentUserKeys: Set<String> {
        Set([renderedCurrentUser.id, renderedCurrentUser.userID, renderedCurrentUser.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_BEGIN
    private func availableContacts(in contacts: [IMUser]) -> [IMUser] {
        contacts
            .filter { user in
                guard !user.isCancelledUser else { return false }
                return ![user.id, user.userID, user.username]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains { currentUserKeys.contains($0) }
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        let store = state.contactStore
        PublisherSnapshotView(
            initialValue: store.contacts,
            updates: store.$contacts.removeDuplicates().eraseToAnyPublisher()
        ) { contacts in
            relationshipContent(contacts: availableContacts(in: contacts))
        }
    }
    // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    private func relationshipContent(contacts allContacts: [IMUser]) -> some View {
        let contacts = IMUserSearchMatcher.sortedMatches(users: allContacts, query: query)
        let identities = Set(contacts.flatMap(state.userIdentityCandidates(for:)))
        let store = state.contactStore
        return PublisherSnapshotView(
            // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
            initialValue: store.callRelationshipSnapshot(matching: identities),
            updates: store.callRelationshipUpdates(matching: identities)
        ) { _ in
            pickerContent(contacts: contacts, hasContacts: !allContacts.isEmpty)
        }
    }

    private func pickerContent(contacts: [IMUser], hasContacts: Bool) -> some View {
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END
        RTCCallContactPickerContent(query: $query, isEmpty: contacts.isEmpty, hasContacts: hasContacts,
            preferredKind: preferredKind, onClose: { dismiss() }) {
            ForEach(contacts) { user in
                RTCCallContactRowContent(name: user.displayName, subtitle: callContactSubtitle(user), avatar: {
                    AvatarView(name: user.displayName, seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: user.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                }, certification: { CertificationPillView(exactUID: user.id, compact: true) },
                voiceAction: { contactCallAction(kind: .voice, user: user) },
                videoAction: { contactCallAction(kind: .video, user: user) })
            }
        }
    }

    private func contactCallAction(kind: RTCCallActionKind, user: IMUser) -> some View {
        RTCCallContactActionContent(kind: kind, userID: user.id, displayName: user.displayName,
            unavailableReason: callUnavailableReason(kind: kind, user: user)) {
            guard state.guardCallLicenseForAction(kind == .voice ? .voice : .video) else { return }
            dismiss()
            onSelect(user, kind)
        }
    }

    private func callUnavailableReason(kind: RTCCallActionKind, user: IMUser) -> String? {
        switch kind {
        case .voice:
            return state.voiceCallUnavailableReason(for: user)
        case .video:
            return state.videoCallEntryUnavailableReason(for: user)
        }
    }

    private func callContactSubtitle(_ user: IMUser) -> String {
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = user.department.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = user.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [userID.isEmpty ? user.id : userID, department, title]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END
