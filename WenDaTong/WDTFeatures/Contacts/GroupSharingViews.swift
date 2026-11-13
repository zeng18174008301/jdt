import IM4Features
import IM4Domain
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit

private struct GroupQRCodeSheet: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode", title: "群二维码", subtitle: "二维码有效期 7 天，入群申请仍需管理员审批。", showsCloseButton: true)
                VStack(spacing: 14) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 86, weight: .regular))
                        .foregroundStyle(IMColor.brand)
                        .frame(width: 174, height: 174)
                        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(IMColor.brand.opacity(0.08)))
                    Text(group.name)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("邀请码 BS-\(group.id.uppercased())")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity)
                .plainCard(radius: 26)

                HStack(spacing: 10) {
                    GroupSheetActionButton(title: "复制链接", symbol: "doc.on.doc.fill") {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("群邀请链接已复制")
                    }
                    GroupSheetActionButton(title: "刷新二维码", symbol: "arrow.clockwise") {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("群二维码已刷新")
                    }
                }
            }
            .padding(18)
        }
    }
}

enum GroupFilePreviewPolicy {
    static func inAppDestination(for file: FileItem) -> FileItem? {
        file.previewAvailable ? file : nil
    }
}

struct GroupFilesSheet: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    @State private var selectedFile: FileItem?
    @State private var shareItem: FileShareItem?
    @State private var forwardingFile: FileItem?
    @State private var downloadingFileID: String?

    // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.fileStore
        // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110
        PublisherSnapshotView(
            initialValue: store.groupFilesSnapshot(groupID: group.id),
            updates: store.groupFilesUpdates(groupID: group.id)
        ) { snapshot in
            state.tenantInteractionStore.observe(\.canForward) { allowed in // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                content(snapshot, canForward: allowed)
            }
        }
        .id(group.id)
        .id(state.contentCacheScopeKey)
    }

    private func content(_ snapshot: FileStore.GroupFilesSnapshot, canForward: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let groupFiles = snapshot.files
        let isSyncing = snapshot.isSyncing
        let syncError = snapshot.syncError
        // WDT_IOS1_REFACTOR_FILE_DOWNLOAD_OBSERVATION_20261110_END
        return GroupFilesContent(isEmpty: groupFiles.isEmpty, isSyncing: isSyncing, syncError: syncError,
            rows: {
                ForEach(groupFiles) { file in
                    GroupFileRowContent(file: file.featureDisplay, canForward: canForward, avatar: {
                        AvatarView(name: file.type, seed: file.accentHex, size: 48)
                    }, progress: {
                        FileDownloadProgress(store: state.fileStore, keys: state.fileDownloadKeys(file)) { snapshot in
                            AttachmentDownloadProgressView(snapshot: snapshot) { state.cancelFileDownload(file) }
                        }
                    }, onOpen: { openGroupFilePreview(file) }, onDownload: {
                        if file.downloadAvailable {
                            prepareGroupFileForSharing(file)
                        } else {
                            state.setToast("该文件暂未开放下载")
                        }
                    }, onForward: { forwardingFile = file })
                }
            }, onRetry: { state.refreshGroupFiles(groupID: group.id, silent: false) })
        .sheet(item: $selectedFile) { file in
            FilePreviewView(file: file)
                .presentationDetentsCompat([.large])
        }
        .sheet(item: $shareItem) { item in
            FileActivityView(activityItems: [item.url])
                .presentationDetentsCompat([.medium, .large])
        }
        .sheet(item: $forwardingFile) { file in
            GroupFileForwardTargetSheet(file: file) {
                forwardingFile = nil
            }
            .presentationDetentsCompat([.large])
        }
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
    }

    private func openGroupFilePreview(_ file: FileItem) {
        if let destination = GroupFilePreviewPolicy.inAppDestination(for: file) {
            selectedFile = destination
        } else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("该文件暂不支持在线预览")
        }
    }

    private func prepareGroupFileForSharing(_ file: FileItem) {
        guard downloadingFileID == nil else { return }
        downloadingFileID = file.id
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("正在准备下载文件")
        let cacheScope = state.contentCacheScopeKey
        Task {
            do {
                let localURL = try await TenantFileSharePreparer.prepare(file: file, state: state, scope: cacheScope)
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        downloadingFileID = nil
                        return
                    }
                    downloadingFileID = nil
                    shareItem = FileShareItem(url: localURL)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件已准备好，可保存或分享")
                }
            } catch {
                await MainActor.run {
                    downloadingFileID = nil
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("文件下载失败，请稍后重试")
                }
            }
        }
    }
			}

private struct GroupFileForwardTargetSheet: View {
    @EnvironmentObject private var state: AppState
    let file: FileItem
    let onComplete: () -> Void
    @State private var query = ""
    @State private var selectedTab: BatchForwardTargetTab = .friend
    @State private var submittingTargetID: String?

    private func candidates(in conversations: [ConversationMessageSnapshot]) -> [BatchForwardTargetCandidate] { // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.batchForwardTargetCandidates(from: conversations).filter { candidate in
            guard candidate.target.tab == selectedTab else { return false }
            guard !normalized.isEmpty else { return true }
            return ([candidate.target.displayName, candidate.subtitle] + candidate.target.searchTerms)
                .contains { $0.lowercased().contains(normalized) }
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(initialValue: store.groups, updates: store.groupDirectoryUpdates) { _ in
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
            ContactDirectoryPresentationView(store: store) {
                // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
                state.conversationStore.observeConversationCollection({
                    $0.filter { $0.kind != .system }.map(\.withoutMessages)
                }) { conversations in
                    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
                    state.tenantInteractionStore.observe(\.canForward) { allowed in
                        groupDependentContent(conversations: conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) }, canForward: allowed)
                    }
                    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    @ViewBuilder
    private func groupDependentContent(conversations: [ConversationMessageSnapshot], canForward: Bool) -> some View { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        GroupFileForwardContent(fileName: file.name, query: $query, selectedTab: $selectedTab) {
            ForEach(candidates(in: conversations)) { candidate in
                let certificationUID = targetCertificationUID(for: candidate)
                GroupFileForwardRowContent(
                    name: candidate.target.displayName,
                    subtitle: candidate.subtitle,
                    isSubmitting: submittingTargetID == candidate.id,
                    isDisabled: submittingTargetID != nil || !canForward,
                    onSelect: {
                        guard submittingTargetID == nil else { return }
                        submittingTargetID = candidate.id
                        Task {
                            let succeeded = await state.forwardTenantFile(file, to: candidate.target)
                            await MainActor.run {
                                submittingTargetID = nil
                                if succeeded { onComplete() }
                            }
                        }
                    }
                ) {
                    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
                    state.certificationPillSource.observe({
                        certificationUID == nil ? 0 : $0.scopeRevision()
                    }) { scopeRevision in
                        AvatarView(
                            name: candidate.target.displayName,
                            seed: candidate.avatarSeed,
                            size: 44,
                            imageURL: candidate.avatarURL,
                            avatarVersion: candidate.avatarVersion,
                            avatarUpdatedAt: candidate.avatarUpdatedAt,
                            certificationReference: certificationUID.flatMap {
                                state.certificationPillSource.reference(forExactUID: $0)
                            }
                        )
                        .task(id: "\(certificationUID ?? "")|\(scopeRevision)") {
                            guard let certificationUID else { return }
                            state.ensureCertificationPresentations(forExactUIDs: [certificationUID])
                        }
                    }
                    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END
                }
            }
        }
    }

    private func targetCertificationUID(for candidate: BatchForwardTargetCandidate) -> String? {
        guard candidate.target.tab == .friend else { return nil }
        // Candidates already carry canonical actor:peer channel IDs. Never
        // decorate a group, an ambiguous channel, or the current user's slot.
        let parts = candidate.target.channelID.split(separator: ":").map(String.init)
        guard parts.count == 2,
              parts.filter({ state.isCurrentUserIdentity($0) }).count == 1,
              let peerUID = parts.first(where: { !state.isCurrentUserIdentity($0) }) else {
            return nil
        }
        return peerUID
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
