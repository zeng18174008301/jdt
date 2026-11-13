// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit
import IM4DesignSystem

// WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110_BEGIN
struct GroupInviteApprovalCard: View {
    let approval: GroupInviteApproval
    var compact = false
    let isProcessing: Bool
    let onReview: @MainActor (Bool) -> Void
    let onCopy: @MainActor (String) -> Void

    private var statusColor: Color {
        if approval.isApproved {
            return IMColor.success
        }
        if approval.isRejected {
            return IMColor.danger
        }
        if approval.isCanceled || approval.isExpired {
            return IMColor.muted
        }
        return IMColor.warning
    }

    private var inviteSummary: String {
        let inviter = approval.inviterName.isEmpty ? "成员" : approval.inviterName
        let invitee = approval.inviteeName.isEmpty ? "用户" : approval.inviteeName
        if approval.isJoinRequest {
            if approval.kind == "group_invite_receipt", approval.isPending {
                return "\(invitee) 的入群申请等待群主或管理员审核"
            }
            return "\(invitee) 申请加入群聊"
        }
        if approval.kind == "group_invite_receipt", approval.isPending {
            return "\(invitee) 的入群邀请等待群主或管理员审核"
        }
        return "\(inviter) 邀请 \(invitee) 入群"
    }

    var body: some View {
        IM4DesignSystem.GroupInviteApprovalContent(
            display: IM4DesignSystem.GroupInviteApprovalDisplay(
                groupName: approval.groupName,
                statusText: approval.statusText,
                isPending: approval.isPending,
                isJoinRequest: approval.isJoinRequest,
                inviterName: approval.inviterName,
                inviterAccountID: approval.inviterAccountID,
                inviteeName: approval.inviteeName,
                inviteeAccountID: approval.inviteeAccountID,
                resultText: approval.resultText,
                actedSummary: approval.actedSummary,
                approverAccountID: approval.approverAccountID,
                showsPendingReceipt: approval.kind == "group_invite_receipt" && approval.isPending,
                showsReviewActions: approval.kind == "group_invite_approval" && approval.isPending,
                rejectDisabled: !approval.canReject || approval.rejectEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing,
                approveDisabled: !approval.canApprove || approval.approveEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing
            ), compact: compact, statusColor: statusColor, inviteSummary: inviteSummary,
            onReview: onReview, onCopy: onCopy
        )
    }




}
// WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110_END
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
