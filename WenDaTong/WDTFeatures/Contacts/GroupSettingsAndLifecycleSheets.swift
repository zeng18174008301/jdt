import IM4Features
import SwiftUI
import UIKit

struct GroupNicknameEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let groupID: String

    @State private var nickname = ""
    @State private var originalNickname = ""
    @State private var isSaving = false
    @State private var inlineMessage: String?
    @State private var didLoad = false

    private var normalizedNickname: String? {
        try? GroupNicknameInputPolicy.normalize(nickname)
    }

    private var validationMessage: String? {
        do {
            _ = try GroupNicknameInputPolicy.normalize(nickname)
            return nil
        } catch let error as GroupNicknameInputError {
            return error.userMessage
        } catch {
            return "群昵称格式不正确"
        }
    }

    private var canSave: Bool {
        guard !isSaving, validationMessage == nil, let normalizedNickname else { return false }
        return normalizedNickname != originalNickname
    }

    var body: some View {
        GroupNicknameEditContent(nickname: $nickname, validationMessage: validationMessage, inlineMessage: inlineMessage,
            clearsNickname: normalizedNickname?.isEmpty == true, canSave: canSave, isSaving: isSaving,
            onClose: { dismiss() }, onSave: save)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            let current = state.myGroupNickname(groupID: groupID)
            originalNickname = current
            nickname = current
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        inlineMessage = nil
        Task {
            let ok = await state.updateMyGroupNickname(groupID: groupID, rawValue: nickname)
            isSaving = false
            if ok {
                inlineMessage = "群昵称保存成功"
                dismiss()
            } else {
                inlineMessage = state.toast ?? "群昵称保存失败"
            }
        }
    }
}

typealias GroupLifecycleActionRow = IM4Features.GroupLifecycleActionRow

struct GroupLeaveDetailSheet: View {
    let group: GroupInfo
    let isSubmitting: Bool
    let isScopeValid: Bool
    let actionErrorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GroupLeaveDetailContent(groupName: group.name, isSubmitting: isSubmitting, isScopeValid: isScopeValid,
            actionErrorMessage: actionErrorMessage, onCancel: {
                onCancel()
                dismiss()
            }, onConfirm: onConfirm)
    }
}

struct GroupDissolveConfirmSheet: View {
    let group: GroupInfo
    let preview: RemoteGroupDissolvePreview?
    let isSubmitting: Bool
    let isPreviewLoading: Bool
    let isScopeValid: Bool
    let isPreviewScopeValid: Bool
    let previewErrorMessage: String?
    let actionErrorMessage: String?
    let onRetryPreview: (() -> Void)?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState

    init(
        group: GroupInfo,
        preview: RemoteGroupDissolvePreview?,
        isSubmitting: Bool,
        isPreviewLoading: Bool = false,
        isScopeValid: Bool = true,
        isPreviewScopeValid: Bool = true,
        previewErrorMessage: String? = nil,
        actionErrorMessage: String? = nil,
        onRetryPreview: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.group = group
        self.preview = preview
        self.isSubmitting = isSubmitting
        self.isPreviewLoading = isPreviewLoading
        self.isScopeValid = isScopeValid
        self.isPreviewScopeValid = isPreviewScopeValid
        self.previewErrorMessage = previewErrorMessage
        self.actionErrorMessage = actionErrorMessage
        self.onRetryPreview = onRetryPreview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var hasUsablePreview: Bool {
        preview?.groupID == group.id && isPreviewScopeValid
    }

    private var canContinue: Bool {
        hasUsablePreview
            && isScopeValid
            && !isPreviewLoading
            && previewErrorMessage == nil
            && !isSubmitting
    }

    private var memberCount: Int? {
        guard state.shouldShowGroupMemberCount,
              let preview,
              preview.groupID == group.id else { return nil }
        let previewCount = preview.memberCount ?? 0
        return previewCount > 0 ? previewCount : group.effectiveMemberCount
    }

    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.tenantClientPolicyStore.observe(\.showsGroupMemberCount) { _ in dissolveContent }
    }

    private var dissolveContent: some View {
    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        GroupDissolveDetailContent(groupName: group.name, isSubmitting: isSubmitting, isPreviewLoading: isPreviewLoading,
            isScopeValid: isScopeValid, canContinue: canContinue, memberCount: memberCount,
            previewErrorMessage: previewErrorMessage, actionErrorMessage: actionErrorMessage, onRetryPreview: onRetryPreview,
            onCancel: {
                onCancel()
                dismiss()
            }, onConfirm: onConfirm)
    }
}
