import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct AboutJianHuiTongView: View {
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    @EnvironmentObject private var state: AppState
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "问达通"
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        AboutAppContent(displayName: displayName, versionText: versionText,
            onLogoTap: { state.registerAccessDiagnosticsLogoTap(entry: .loggedInAboutLogo) }) {
            LegalDocumentLinksView(prefix: "", style: .settings)
        }
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        .onDisappear {
            state.resetAccessDiagnosticsLogoTapSequence(entry: .loggedInAboutLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

}

private typealias AboutAppMark = IM4Features.AboutAppMark

private typealias AboutInfoRow = IM4Features.AboutInfoRow

struct ContactUsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var isRefreshingPolicy = false

    private var policy: RemoteAppCurrentPolicy? {
        state.currentAppPolicy
    }

    private var normalizedEmail: String? {
        SupportContactMailto.normalizedEmail(policy?.supportContactEmail ?? "")
    }

    private var isEmailConfigured: Bool {
        policy?.supportContactConfigured == true && normalizedEmail != nil
    }

    private var statusText: String {
        if isEmailConfigured { return "点击邮箱或发送邮件按钮联系我们。" }
        if state.currentAppPolicyErrorMessage != nil { return "应用策略暂不可用，请稍后重试。" }
        return "暂未配置联系邮箱"
    }

    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.appPolicyPresentationStore.observe(\.supportContact) { _ in supportContent }
    }

    private var supportContent: some View {
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
        SupportContactContent(isEmailConfigured: isEmailConfigured, normalizedEmail: normalizedEmail,
            statusText: statusText, isRefreshingPolicy: isRefreshingPolicy, onOpenMail: openMail)
        .task {
            await refreshPolicy()
        }
    }

    private func refreshPolicy() async {
        guard !isRefreshingPolicy else { return }
        isRefreshingPolicy = true
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        isRefreshingPolicy = false
    }

    private func openMail(_ email: String) {
        guard let url = SupportContactMailto.mailtoURL(email: email) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("联系邮箱不可用")
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            UIPasteboard.general.string = email
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("已复制联系邮箱")
        }
    }
}

struct AccountCancellationView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isSubmitting = false

    private let deletionNotice = "注销后将立即删除：用户姓名、手机号、电子邮箱。实名认证信息。用户的设备标识符、绑定关系。用户在 App 内生成的非必要历史记录。"

    var body: some View {
        AccountCancellationContent(reason: $reason, isSubmitting: isSubmitting, deletionNotice: deletionNotice,
            onDismiss: { dismiss() }, onSubmit: submitCancellation)
    }

    private func submitCancellation() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let success = await state.cancelCurrentAccount(reason: trimmedReason.isEmpty ? nil : trimmedReason)
            isSubmitting = false
            if success {
                dismiss()
            }
        }
    }
}
