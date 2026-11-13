import SwiftUI
import IM4Features
import UIKit

// WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
private struct ContactDirectoryPresentationKey: EnvironmentKey {
    static let defaultValue: ContactStore.DirectoryPresentationSnapshot? = nil
}

extension EnvironmentValues {
    var contactDirectoryPresentation: ContactStore.DirectoryPresentationSnapshot? {
        get { self[ContactDirectoryPresentationKey.self] }
        set { self[ContactDirectoryPresentationKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

// WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_BEGIN
/// Observes the live directory only while a directory-dependent surface is mounted.
struct ContactDirectoryPresentationView<Content: View>: View {
    let store: ContactStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        PublisherSnapshotView(
            initialValue: store.directoryPresentationSnapshot,
            updates: store.directoryPresentationUpdates
        ) { directory in
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
            content().environment(\.contactDirectoryPresentation, directory)
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END
        }
    }
}
// WDT_IOS1_REFACTOR_CONTACT_PICKER_OBSERVATION_20261110_END

// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
struct ContactDirectoryRow: View {
    let row: ContactDirectoryRowPresentation
    var body: some View {
        let user = row.user
        ContactDirectoryRowContent(row: row.featureInput(), avatar: {
            AvatarView(name: row.displayName, seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL,
                avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: row.certification)
        }, certification: {
            if let certification = row.certification {
                CertificationPillView(exactUID: user.id, compact: true, presentation: certification, usesProvidedPresentationOnly: true)
            }
        })
    }
}
struct ContactRow: View {
    @EnvironmentObject private var state: AppState
    let user: IMUser
    var body: some View {
        let displayName = state.remarkPreferredDisplayName(for: user)
        ContactRowContent(displayName: displayName, userNumber: contactAuthoritativeUserNumber(userID: user.userID),
            isCancelled: user.isCancelledUser, avatar: {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 48, imageURL: user.displayAvatarURL,
                    avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt,
                    certificationReference: state.certificationPillSource.reference(forExactUID: user.id))
            }, certification: { CertificationPillView(exactUID: user.id, compact: true) })
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
typealias SettingsRow = IM4Features.SettingsRow
// WDT_IOS1_FEATURES_ME_UI_20261111_END

// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
func contactAuthoritativeUserNumber(userID: String) -> String? {
    let normalized = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

func accessibilityContactUserNumber(_ userID: String) -> String? {
    contactAuthoritativeUserNumber(userID: userID).map { "用户编号 \($0)" }
}

enum OtherUserAvatarPreviewPolicy {
    static func source(
        for user: IMUser,
        isSelf: Bool,
        isCancelled: Bool
    ) -> String? {
        guard !isSelf, !isCancelled else { return nil }
        let source = user.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              TenantRelativeImageURLResolver.request(source, routeContext: nil) != nil else {
            return nil
        }
        let normalizedSource = source
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .lowercased()
        let normalizedVersion = user.avatarVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let placeholderMarkers = [
            "/static/avatars/default-users/",
            "/static/avatars/default-users-v2/",
            "/avatars/user-default-avatar",
            "/avatars/default-user-avatar",
            "/avatars/user-cancelled-gray.svg"
        ]
        let isSystemPlaceholder = placeholderMarkers.contains { normalizedSource.contains($0) }
            || normalizedVersion.hasPrefix("default-user-avatar-")
            || normalizedVersion.hasPrefix("default-avatar-v2:")
        return isSystemPlaceholder ? nil : source
    }
}
// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

struct GroupMemberStatsCard: View {
    @Environment(\.tenantShowsGroupMemberCount) private var showsGroupCount // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
    let group: GroupInfo
    let ownerName: String
    @EnvironmentObject private var state: AppState

    var body: some View {
        GroupMemberStatsContent(memberCount: state.visibleGroupMemberCount(group.memberCount, showsCount: showsGroupCount),
            ownerName: ownerName, adminCount: (showsGroupCount ?? state.shouldShowGroupMemberCount) ? group.adminCount : nil)
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

// WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110_BEGIN
// JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ROUTE_MODEL - 修改开始：通讯录/群列表进入聊天使用一次性 route，避免空 destination
struct ContactsConversationRoute: Identifiable, Hashable {
    let id = UUID()
    let conversationID: String
    init(id conversationID: String) {
        self.conversationID = conversationID
    }
}
// JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ROUTE_MODEL - 修改结束
// WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110_END
