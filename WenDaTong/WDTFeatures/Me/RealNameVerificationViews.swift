import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct RealNameVerificationFlowView: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var realName = ""
    @State private var idNumber = ""
    @State private var fieldError = ""
    @State private var isSubmitting = false

    private var normalizedStatus: String {
        renderedCurrentUser.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canEditRealName: Bool {
        !renderedCurrentUser.realNameVerified && normalizedStatus != "pending"
    }

    private var canSubmit: Bool {
        !realName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !idNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
            && canEditRealName
    }

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.verification)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        RealNameVerificationContent(realName: $realName, idNumber: $idNumber, fieldError: fieldError,
            realNameStatusSymbol: realNameStatusSymbol, realNameStatusTitle: realNameStatusTitle,
            realNameStatusSubtitle: realNameStatusSubtitle, realNameStatusColor: realNameStatusColor,
            canEditRealName: canEditRealName, isSubmitting: isSubmitting, canSubmit: canSubmit,
            onNameChange: { fieldError = "" }, onIDChange: normalizeIDInput, onSubmit: submit)
        .onAppear {
            fieldError = "" // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110
            Task { await state.refreshVerificationStatus() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }

    private func normalizeIDInput(_ newValue: String) {
        idNumber = RealNameValidator.sanitizedIDNumber(newValue)
        fieldError = ""
    }

    private func submit() {
        guard !isSubmitting else { return }
        guard validateFields() else { return }
        // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_BEGIN
        isSubmitting = true
        let submittedName = realName
        let submittedID = idNumber
        Task {
            let result = await state.submitRealNameVerification(realName: submittedName, idNumber: submittedID)
            isSubmitting = false
            switch result {
            case .accepted:
                dismiss()
            case .rejected(let message):
                if realName == submittedName, idNumber == submittedID, fieldError.isEmpty {
                    fieldError = message
                }
            }
        }
        // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110_END
    }

    private func validateFields() -> Bool {
        let normalizedName = realName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = RealNameValidator.sanitizedIDNumber(idNumber)
        if !RealNameValidator.isValidName(normalizedName) {
            fieldError = "请输入有效真实姓名，仅支持2-20位中文字符，可包含“·”。"
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("真实姓名格式不正确")
            return false
        }
        if !RealNameValidator.isValidChineseResidentID(normalizedID) {
            fieldError = "请输入有效的15或18位身份证号码，18位末位校验码可为数字或X。"
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("身份证号码格式不正确")
            return false
        }
        realName = normalizedName
        idNumber = normalizedID
        fieldError = ""
        return true
    }

    private var realNameStatusSymbol: String {
        if renderedCurrentUser.realNameVerified { return "checkmark.seal.fill" }
        switch normalizedStatus {
        case "pending": return "clock.fill"
        case "rejected": return "exclamationmark.triangle.fill"
        default: return "person.text.rectangle.fill"
        }
    }

    private var realNameStatusTitle: String {
        if renderedCurrentUser.realNameVerified { return "实名已认证" }
        switch normalizedStatus {
        case "pending": return "审核中"
        case "rejected": return "认证未通过"
        default: return "实名未认证"
        }
    }

    private var realNameStatusSubtitle: String {
        if renderedCurrentUser.realNameVerified {
            return "身份信息已通过审核，可用于账号安全校验。"
        }
        switch normalizedStatus {
        case "pending":
            return "已提交认证申请，审核完成后状态会自动更新。"
        case "rejected":
            return "请核对真实姓名与证件号码后重新提交。"
        default:
            return "请填写真实姓名与证件号码完成认证。"
        }
    }

    private var realNameStatusColor: Color {
        if renderedCurrentUser.realNameVerified { return IMColor.success }
        switch normalizedStatus {
        case "pending": return IMColor.brand
        case "rejected": return IMColor.danger
        default: return IMColor.muted
        }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private typealias RealNameStatusHeroCard = IM4Features.RealNameStatusHeroCard
