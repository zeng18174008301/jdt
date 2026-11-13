import IM4Features
import SwiftUI
import UIKit

// WDT_CHAT_FIX4_USER_ID_HINT_20261023_BEGIN
func findUserNumericIDHint(userID: String) -> String? {
    let id = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let component = id.split(separator: "-", omittingEmptySubsequences: false).last else { return nil }
    let digits = (component.first == "U" || component.first == "u") ? component.dropFirst() : component[...]
    guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return "你ID是“\(id)”，对方只需输入“\(digits)”即可找到你。"
}
// WDT_CHAT_FIX4_USER_ID_HINT_20261023_END

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct FindUserSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var applyMessage = ""
    @State private var results: [UserSearchResult] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var applyingID: String?
    @State private var observedAvatarRevision: Int64? // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110

    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        state.tenantClientPolicyStore.observe(\.allowsMemberFriendRequests) { enabled in
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
            state.enterpriseMembershipStore.observe(\.current.role) { role in
                policyContent(canInitiate: AppState.canInitiateFriendRequest(role: role, enabled: enabled))
            }
            // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
        }
    }

    private func policyContent(canInitiate: Bool) -> some View {
    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        FindUserContent(keyword: $keyword, applyMessage: $applyMessage, hint: findUserNumericIDHint(userID: renderedCurrentUser.userID),
            results: results, hasSearched: hasSearched, isSearching: isSearching, onSearch: performSearch,
            onClear: {
                keyword = ""
                results = []
                hasSearched = false
            }, onClose: { dismiss() }) { item in
                userResultRow(item, canInitiate: canInitiate)
            }
        .onAppear {
                if applyMessage.isEmpty {
                    applyMessage = "我是 \(state.currentUser.name)"
                }
            }
            // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
        .onReceive(state.avatarSearchPresentationStore.$revision) { revision in
                if let observedAvatarRevision, observedAvatarRevision != revision {
                    results = state.projectAvatarRealtime(results)
                }
                observedAvatarRevision = revision
            }
            // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END
    }

    private func userResultRow(_ item: UserSearchResult, canInitiate: Bool) -> some View {
        let liveItem = item
        let canApply = canSubmitFriendRequest(item, canInitiate: canInitiate)
        return FindUserResultContent(item: liveItem, relationTitle: relationTitle(item, canInitiate: canInitiate),
            relationColor: relationColor(item, canInitiate: canInitiate), canApply: canApply,
            isApplying: applyingID == item.id, isAnyApplying: applyingID != nil,
            buttonTitle: canApply ? FriendAddPresentation.actionTitle : actionTitle(item, canInitiate: canInitiate),
            onCopy: state.copyUserID, onApply: { apply(item) }, avatar: {
                AvatarView(
                    name: liveItem.displayName,
                    seed: userSearchSeed(liveItem.id),
                    size: 48,
                    imageURL: liveItem.avatarURL,
                    certificationReference: state.certificationPillSource.reference( // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                        forExactUID: liveItem.id
                    )
                )
            }, certification: { CertificationPillView(exactUID: liveItem.id, compact: true) })
    }

    private func canSubmitFriendRequest(_ item: UserSearchResult, canInitiate: Bool) -> Bool {
        canInitiate && item.canApplyFriend
    }

    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入用户ID的纯数字部分")
            return
        }
        isSearching = true
        hasSearched = true
        Task {
            let items = await state.searchTenantUsers(keyword: trimmed)
            await MainActor.run {
                results = state.projectAvatarRealtime(items)
                isSearching = false
            }
        }
    }

    private func apply(_ item: UserSearchResult) {
        guard applyingID == nil else { return }
        applyingID = item.id
        Task {
            let updated = await state.applyFriendFromSearch(item, message: applyMessage)
            await MainActor.run {
                if let updated, let index = results.firstIndex(where: { $0.id == updated.id }) {
                    results[index] = updated
                }
                applyingID = nil
            }
        }
    }

    private func relationTitle(_ item: UserSearchResult, canInitiate: Bool) -> String {
        switch item.relationStatus {
        case "friend": return "已是好友"
        case "pending_in": return "待我处理"
        case "pending_out": return FriendAddPresentation.waitingTitle
        case "blocked": return "不可添加"
        case "self": return "本人"
        default: return canSubmitFriendRequest(item, canInitiate: canInitiate) ? "可添加" : "不可添加"
        }
    }

    private func actionTitle(_ item: UserSearchResult, canInitiate: Bool) -> String {
        if item.canApplyFriend && !canInitiate {
            return "已关闭"
        }
        switch item.relationStatus {
        case "friend": return "好友"
        case "pending_in": return "待处理"
        case "pending_out": return FriendAddPresentation.waitingTitle
        case "self": return "本人"
        default: return "不可用"
        }
    }

    private func relationColor(_ item: UserSearchResult, canInitiate: Bool) -> Color {
        switch item.relationStatus {
        case "friend": return IMColor.success
        case "pending_in", "pending_out": return IMColor.warning
        case "blocked": return IMColor.danger
        case "self": return IMColor.muted
        default: return canSubmitFriendRequest(item, canInitiate: canInitiate) ? IMColor.brand : IMColor.muted
        }
    }

    private func userSearchSeed(_ key: String) -> UInt {
        key.unicodeScalars.reduce(UInt(5381)) { partial, scalar in
            ((partial << 5) &+ partial) &+ UInt(scalar.value)
        }
    }


}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END
