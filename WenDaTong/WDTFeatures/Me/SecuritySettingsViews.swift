import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct SecuritySettingsView: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState

    private var loginAccountText: String {
        let username = renderedCurrentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "未设置" : username
    }

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.identity)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        SecuritySettingsContent(loginAccountText: loginAccountText, onCopy: state.copyUserID,
            password: { PasswordSettingsFlowView() }, faceID: { FaceIDSettingsFlowView() }, faceIDLabel: {
                state.biometricAccessStore.observe(\.settings.enabled) { enabled in
                    SecurityActionRow(symbol: "faceid", title: "Face ID", subtitle: "解锁会话和文件预览",
                        value: enabled ? "已开启" : "未开启")
                }
            }, deviceLimit: {
                state.tenantDevicePolicyPresentationStore.observe { text in
                    SecurityInfoRowContent(symbol: "number.circle.fill", title: "设备上限", value: text, onCopy: state.copyUserID)
                }
            }, loginLog: {
                SecurityLoginLogSection(store: state.loginLogStore, reload: state.refreshLoginLogs)
            })
        .task {
            await state.refreshLoginLogs()
        }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_BEGIN
private struct SecurityLoginLogSection: View {
    @ObservedObject var store: LoginLogStore
    let reload: @MainActor () async -> Void

    var body: some View {
        SecurityLoginLogContent(isLoading: store.isLoading, loadFailed: store.loadFailed, logs: store.logs, reload: reload)
    }
}
// WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_END

private struct PasswordSettingsFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var verified = false
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword.count <= 20
            && newPassword.rangeOfCharacter(from: .letters) != nil
            && newPassword.rangeOfCharacter(from: .decimalDigits) != nil
            && newPassword == confirmPassword
            && verified
    }

    var body: some View {
        SecurityPasswordContent(currentPassword: $currentPassword, newPassword: $newPassword,
            confirmPassword: $confirmPassword, verified: $verified, canSubmit: canSubmit,
            isSubmitting: isSubmitting, onSubmit: submit)
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let saved = await state.changeMyPassword(currentPassword: currentPassword, newPassword: newPassword)
            await MainActor.run {
                isSubmitting = false
                if saved {
                    dismiss()
                }
            }
        }
    }
}

private struct FaceIDSettingsFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BiometricProtectionSettingsDraft(settings: .disabled)
    @State private var sliderVerified = false

    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.biometricAccessStore.observe(\.settings) { settings in
            settingsContent(settings)
        }
    }

    private func settingsContent(_ settings: BiometricProtectionSettings) -> some View {
        let hasChanges = draft.hasChanges(comparedTo: settings)
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
        // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_BEGIN
        return SecurityFaceIDContent(enabled: Binding(get: { draft.enabled }, set: { value in requestEnabledChange(value) }),
            unlockChats: $draft.unlockChats, previewFiles: $draft.previewFiles, sliderVerified: $sliderVerified,
            isUpdating: draft.isUpdating, hasChanges: hasChanges, onSave: saveDraft)
        // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_END
        .onAppear {
            draft.synchronize(with: state.biometricProtectionSettings)
        }
        .onChangeCompat(of: settings) { _, settings in // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110
            draft.synchronize(with: settings)
        }
    }

    private func requestEnabledChange(_ requestedEnabled: Bool) {
        guard sliderVerified else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请先完成滑块验证")
            return
        }
        guard let requested = draft.beginEnabledChange(to: requestedEnabled) else { return }
        Task {
            let succeeded = await state.saveBiometricProtectionSettings(
                enabled: requested.enabled,
                unlockChats: requested.unlockChats,
                previewFiles: requested.previewFiles
            )
            draft.finish(with: state.biometricProtectionSettings)
            if succeeded { sliderVerified = false }
        }
    }

    private func saveDraft() {
        guard sliderVerified else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请先完成滑块验证")
            return
        }
        guard let requested = draft.beginSave(comparedTo: state.biometricProtectionSettings) else { return }
        Task {
            let succeeded = await state.saveBiometricProtectionSettings(
                enabled: requested.enabled,
                unlockChats: requested.unlockChats,
                previewFiles: requested.previewFiles
            )
            draft.finish(with: state.biometricProtectionSettings)
            if succeeded { sliderVerified = false }
            if succeeded { dismiss() }
        }
    }
}

private typealias SecurityActionRow = IM4Features.SecurityActionRow

private typealias SecurityToggleRow = IM4Features.SecurityToggleRow

private typealias SecurityIcon = IM4Features.SecurityIcon

private typealias SecurityDivider = IM4Features.SecurityDivider

private typealias SecuritySectionTitle = IM4Features.SecuritySectionTitle

private typealias SecurityRequirementLine = IM4Features.SecurityRequirementLine

private typealias SecurityHintCard = IM4Features.SecurityHintCard
