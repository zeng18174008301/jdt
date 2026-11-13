import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct PhoneBindingFlowView: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @State private var phone = ""
    @State private var code = ""
    @State private var isSendingCode = false
    @State private var codeCooldown = 0
    @State private var isSubmitting = false

    private var normalizedPhone: String {
        normalizedMainlandPhone(phone)
    }

    private var phoneIsValid: Bool {
        isValidMainlandPhone(normalizedPhone)
    }

    private var canSubmit: Bool {
        phoneIsValid
            && code.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
            && !isSubmitting
            && !renderedCurrentUser.phoneVerified
    }

    private var phoneDisplayText: String {
        let display = settingsPhoneDisplayText(renderedCurrentUser.phone)
        return display == "未绑定" ? "未绑定手机号" : display
    }

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.phone)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        PhoneBindingScreenContent(isVerified: currentUserSnapshot.phoneVerified, phoneDisplayText: phoneDisplayText,
            form: phoneBindingForm)
        .onAppear {
            let currentPhone = state.currentUser.phone
            phone = currentPhone.contains("*") || currentPhone.contains("•") ? "" : normalizedMainlandPhone(currentPhone)
            Task { await state.refreshVerificationStatus() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if codeCooldown > 0 {
                codeCooldown -= 1
            }
        }
    }

    private var phoneBindingCaptchaTitle: String {
        if isSendingCode { return "发送中" }
        if codeCooldown > 0 { return "\(codeCooldown)s" }
        return "获取验证码"
    }

    private var phoneBindingForm: some View {
        PhoneBindingFormContent(phone: $phone, code: $code, phoneIsValid: phoneIsValid,
            isSendingCode: isSendingCode, codeCooldown: codeCooldown, phoneBindingCaptchaTitle: phoneBindingCaptchaTitle,
            canSubmit: canSubmit, isSubmitting: isSubmitting, onPhoneChange: normalizePhoneInput,
            onSendCode: sendCode, onSubmit: submit)
    }

    private func normalizePhoneInput(_ newValue: String) {
        let normalized = normalizedMainlandPhone(newValue)
        if normalized != newValue {
            phone = normalized
        }
    }

    private func sendCode() {
        guard !isSendingCode, codeCooldown == 0, phoneIsValid else { return }
        isSendingCode = true
        Task {
            let cooldown = await state.sendPhoneBindingCode(phone: normalizedPhone)
            await MainActor.run {
                isSendingCode = false
                if let cooldown {
                    codeCooldown = cooldown
                }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let ok = await state.verifyPhoneBinding(phone: normalizedPhone, code: code)
            isSubmitting = false
            if ok {
                phone = ""
                code = ""
            }
        }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private typealias PhoneBindingStatusPanel = IM4Features.PhoneBindingStatusPanel

private typealias PhoneBindingInfoTile = IM4Features.PhoneBindingInfoTile

func settingsPhoneDisplayText(_ phone: String) -> String {
    maskedPhoneDisplayText(phone, emptyText: "未绑定")
}
