import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

struct ForgotPasswordView: View {
    @EnvironmentObject private var state: AppState
    @State private var account = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isSendingCode = false
    @State private var isResetting = false
    @State private var captchaCooldown = 0
    @FocusState private var focusedField: AuthInputField?

    private var canReset: Bool {
        !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
            && newPassword.count >= 8 && newPassword.count <= 20
            && newPassword.rangeOfCharacter(from: .letters) != nil
            && newPassword.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func backToLogin() { state.setAuthScreen(.accountLogin) } // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

    private func submitReset() {
        guard !isResetting else { return }
        focusedField = nil
        isResetting = true
        Task {
            let succeeded = await state.resetPassword(
                account: account,
                code: code,
                newPassword: newPassword
            )
            await MainActor.run {
                isResetting = false
                guard succeeded else { return }
                state.clearRememberedLoginCredentials()
                state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            }
        }
    }

    var body: some View {
        AuthForgotPasswordContent(account: $account, code: $code, newPassword: $newPassword,
            focusedField: $focusedField, isSendingCode: isSendingCode, isResetting: isResetting,
            captchaCooldown: captchaCooldown, canReset: canReset, onSendCode: sendResetCode,
            onReset: submitReset, onBack: backToLogin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if captchaCooldown > 0 {
                    captchaCooldown -= 1
                }
            }
    }

    private func sendResetCode() {
        guard !isSendingCode, captchaCooldown == 0 else { return }
        isSendingCode = true
        Task {
            let cooldown = await state.sendPasswordResetCaptcha(account: account)
            await MainActor.run {
                isSendingCode = false
                if let cooldown {
                    captchaCooldown = cooldown
                }
            }
        }
    }
}
