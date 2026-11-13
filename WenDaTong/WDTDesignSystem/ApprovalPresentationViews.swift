// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import SwiftUI

public struct GroupInviteApprovalDisplay {
    let groupName: String
    let statusText: String
    let isPending: Bool
    let isJoinRequest: Bool
    let inviterName: String
    let inviterAccountID: String
    let inviteeName: String
    let inviteeAccountID: String
    let resultText: String
    let actedSummary: String
    let approverAccountID: String
    let showsPendingReceipt: Bool
    let showsReviewActions: Bool
    let rejectDisabled: Bool
    let approveDisabled: Bool
    public init(
        groupName: String,
        statusText: String,
        isPending: Bool,
        isJoinRequest: Bool,
        inviterName: String,
        inviterAccountID: String,
        inviteeName: String,
        inviteeAccountID: String,
        resultText: String,
        actedSummary: String,
        approverAccountID: String,
        showsPendingReceipt: Bool,
        showsReviewActions: Bool,
        rejectDisabled: Bool,
        approveDisabled: Bool
    ) {
        self.groupName = groupName
        self.statusText = statusText
        self.isPending = isPending
        self.isJoinRequest = isJoinRequest
        self.inviterName = inviterName
        self.inviterAccountID = inviterAccountID
        self.inviteeName = inviteeName
        self.inviteeAccountID = inviteeAccountID
        self.resultText = resultText
        self.actedSummary = actedSummary
        self.approverAccountID = approverAccountID
        self.showsPendingReceipt = showsPendingReceipt
        self.showsReviewActions = showsReviewActions
        self.rejectDisabled = rejectDisabled
        self.approveDisabled = approveDisabled
    }
}

public struct GroupInviteApprovalContent: View {
    let approval: GroupInviteApprovalDisplay
    let compact: Bool
    let statusColor: Color
    let inviteSummary: String
    let onReview: @MainActor (Bool) -> Void
    let onCopy: @MainActor (String) -> Void
    public init(display: GroupInviteApprovalDisplay, compact: Bool, statusColor: Color, inviteSummary: String,
        onReview: @escaping @MainActor (Bool) -> Void, onCopy: @escaping @MainActor (String) -> Void) {
        self.approval = display
        self.compact = compact
        self.statusColor = statusColor
        self.inviteSummary = inviteSummary
        self.onReview = onReview
        self.onCopy = onCopy
    }
    public var body: some View {

        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approval.isPending ? "person.2.badge.gearshape.fill" : "person.2.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(statusColor)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(statusColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 5) {
                    Text(approval.groupName.isEmpty ? "群邀请审批" : approval.groupName)
                        .font(.system(size: compact ? 15 : 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    Text(inviteSummary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                StatusPill(title: approval.statusText, color: statusColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                if approval.isJoinRequest {
                    approvalMetaRow(title: "申请人", value: accountText(name: approval.inviteeName, accountID: approval.inviteeAccountID), copyValue: approval.inviteeAccountID)
                } else {
                    approvalMetaRow(title: "邀请人", value: accountText(name: approval.inviterName, accountID: approval.inviterAccountID), copyValue: approval.inviterAccountID)
                    approvalMetaRow(title: "被邀请人", value: accountText(name: approval.inviteeName, accountID: approval.inviteeAccountID), copyValue: approval.inviteeAccountID)
                }
                if !approval.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !approval.isPending {
                    approvalMetaRow(title: "处理结果", value: approval.resultText)
                }
                if !approval.actedSummary.isEmpty {
                    approvalMetaRow(title: "处理记录", value: approval.actedSummary)
                }
                if !approval.approverAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    approvalMetaRow(title: "处理人ID", value: approval.approverAccountID, copyValue: approval.approverAccountID)
                }
            }

            if approval.showsPendingReceipt {
                Label(approval.isJoinRequest ? "已提交申请，等待审核结果" : "已提交邀请，等待审核结果", systemImage: "clock.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IMColor.warning.opacity(0.10)))
            }

            if approval.showsReviewActions {
                let rejectDisabled = approval.rejectDisabled
                let approveDisabled = approval.approveDisabled
                HStack(spacing: 10) {
                    Button {
                        onReview(false)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(IMColor.danger)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IMColor.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(rejectDisabled)
                    .opacity(rejectDisabled ? 0.46 : 1)

                    Button {
                        onReview(true)
                    } label: {
                        Label("通过", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .disabled(approveDisabled)
                    .opacity(approveDisabled ? 0.46 : 1)
                }
            }
        }
        .padding(compact ? 12 : 15)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                        .stroke(statusColor.opacity(approval.isPending ? 0.28 : 0.16), lineWidth: 1)
                )
        )
        }

    private func approvalMetaRow(title: String, value: String, copyValue: String? = nil) -> some View {
        let normalizedCopyValue = copyValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.ink.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            guard let normalizedCopyValue else { return }
            onCopy(normalizedCopyValue)
        })
        .accessibilityLabel(normalizedCopyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制用户ID")
    }

    private func accountText(name: String, accountID: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAccount.isEmpty { return trimmedName.isEmpty ? "未知用户" : trimmedName }
        if trimmedName.isEmpty { return trimmedAccount }
        return "\(trimmedName) · \(trimmedAccount)"
    }

}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
