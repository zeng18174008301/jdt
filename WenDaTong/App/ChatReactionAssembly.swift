import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

struct EmojiPickerRuntimeContext: Equatable {
    let scope: EmojiPickerScope
    let catalogBaseURL: URL
}

@MainActor
func currentEmojiPickerRuntimeContext(state: AppState) -> EmojiPickerRuntimeContext? {
    guard state.isAuthenticated else { return nil }
    let context = IMAPIContext.load()
    let appID = IMAPIContext.normalizedIOSAppID(context.appID)
    let accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let currentTenantID = state.currentEnterprise.id.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentUserIDs = Set([
        state.currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines),
        state.currentUser.userID.trimmingCharacters(in: .whitespacesAndNewlines),
    ].filter { !$0.isEmpty })
    guard context.hasIMSession,
          !accountID.isEmpty,
          tenantID == currentTenantID,
          currentUserIDs.contains(imUID),
          let scope = try? EmojiPickerScope(
              product: "ios",
              appID: appID,
              accountID: accountID,
              tenantID: tenantID,
              imUID: imUID
          ) else {
        return nil
    }

    let catalogBaseURL = IMAPIClient.normalizedIMAPIBaseURL(context.imAPIBaseURL)
        ?? IMAPIClient.configuredAPIBases().imBase
    guard catalogBaseURL.host?.hasSuffix(".invalid") != true else { return nil }
    return EmojiPickerRuntimeContext(scope: scope, catalogBaseURL: catalogBaseURL)
}

@MainActor
func emojiPickerRuntimeTaskKey(state: AppState, isOpen: Bool, enterpriseID: String? = nil, identity: CurrentUserPresentationStore.Identity? = nil) -> String {
    [
        state.isAuthenticated ? "authenticated" : "signed-out",
        state.currentAppID,
        enterpriseID ?? state.currentEnterprise.id, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        identity?.id ?? state.currentUser.id, // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        identity?.userID ?? state.currentUser.userID, // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        isOpen ? "open" : "closed",
    ].joined(separator: "|")
}

struct ReactionPickerView: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    var fullPicker: AnyView? = nil
    @State private var emojiPickerStore: EmojiPickerStoreAdapter?
    var body: some View {
        state.observeChatSecondaryEntry { entry in
            state.authenticationPresentationStore.observeAuthentication { authenticated in
                state.enterpriseMembershipStore.observe(\.current.id) { enterpriseID in
                    state.currentUserPresentationStore.observe(CurrentUserPresentationStore.identity) { identity in
                        let lifecycle = ChatReactionLifecycleInput(authenticated: authenticated,
                            originalTaskKey: emojiPickerRuntimeTaskKey(state: state, isOpen: true, enterpriseID: enterpriseID, identity: identity),
                            bindingGeneration: entry.generation, sessionGeneration: entry.identity.sessionGeneration,
                            sessionEpoch: entry.identity.sessionEpoch, authoritySessionID: entry.identity.authoritySessionID)
                        ReactionPickerContent(message: message,
                            onReact: { emoji in
                                guard entry.isCurrent(state) else { return false }
                                state.addReaction(emoji, to: message.id, in: conversationID)
                                return true
                            }, fullPicker: { onSelected in makeFullPicker(entry: entry, onSelected: onSelected) },
                            lifecycle: lifecycle, synchronize: { await synchronizeEmojiPickerRuntime(entry: entry) },
                            signedOut: {
                                emojiPickerStore?.clearIdentity()
                                emojiPickerStore = nil
                                state.emojiPickerCatalogRuntime.reset()
                            }, disappeared: { purgeEmojiPickerIfIdentityChanged() })
                    }
                }
            }
        }
    }
    private func makeFullPicker(entry: ChatSecondaryEntry, onSelected: @escaping () -> Void) -> AnyView? {
        if let fullPicker { return fullPicker }
        guard let emojiPickerStore else { return nil }
        return AnyView(EmojiPickerView(store: emojiPickerStore, onSelect: { item in
            guard entry.isCurrent(state) else { return }
            state.addReaction(item.emoji, to: message.id, in: conversationID)
            emojiPickerStore.close()
            onSelected()
        }))
    }
    @MainActor
    private func synchronizeEmojiPickerRuntime(entry: ChatSecondaryEntry) async {
        guard entry.isCurrent(state), fullPicker == nil else { return }
        guard let runtime = currentEmojiPickerRuntimeContext(state: state) else {
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            state.emojiPickerCatalogRuntime.reset()
            return
        }
        if let emojiPickerStore {
            if emojiPickerStore.scope != runtime.scope {
                emojiPickerStore.switchScope(to: runtime.scope)
                state.emojiPickerCatalogRuntime.reset()
            }
            return
        }
        switch state.emojiPickerCatalogRuntime.begin(
            scope: runtime.scope,
            baseURL: runtime.catalogBaseURL
        ) {
        case .useCatalog(let catalog):
            emojiPickerStore = try? EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .reaction
            )
            return
        case .useFallback:
            return
        case .attempt:
            break
        }
        do {
            let catalog = try await EmojiPickerCatalogLoader().load(baseURL: runtime.catalogBaseURL)
            guard currentEmojiPickerRuntimeContext(state: state) == runtime else {
                state.emojiPickerCatalogRuntime.cancelAttempt(
                    scope: runtime.scope,
                    baseURL: runtime.catalogBaseURL
                )
                return
            }
            let store = try EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .reaction
            )
            guard state.emojiPickerCatalogRuntime.recordSuccess(
                catalog,
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            ) else { return }
            emojiPickerStore = store
        } catch is CancellationError {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch let error as URLError where error.code == .cancelled {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch {
            guard state.emojiPickerCatalogRuntime.recordFailure(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            ) else { return }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("表情目录暂不可用，已使用本地 Emoji")
        }
    }

    @MainActor
    private func purgeEmojiPickerIfIdentityChanged() {
        guard let emojiPickerStore,
              currentEmojiPickerRuntimeContext(state: state)?.scope != emojiPickerStore.scope
        else {
            return
        }
        emojiPickerStore.clearIdentity()
        self.emojiPickerStore = nil
    }


}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
