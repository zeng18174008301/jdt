import Foundation
import IM4Data

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteMyInviteCode = IM4Data.RemoteMyInviteCode

extension RemoteMyInviteCode {
    var memberInviteCode: String {
        item?.memberInviteCode.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var isSyncFailed: Bool {
        item?.syncStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "failed"
    }

    var isUsableForRegistration: Bool {
        enabled && !isSyncFailed && !memberInviteCode.isEmpty
    }

    var shouldHidePersonalInviteModule: Bool {
        !enabled
            && item == nil
            && reasonCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "member_invite_code_role_not_allowed"
    }

    func matchesAuthority(tenantID: String, imUID: String) -> Bool {
        guard let item else { return true }
        let expectedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedIMUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseTenantID = item.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseIMUID = item.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !expectedTenantID.isEmpty
            && !expectedIMUID.isEmpty
            && responseTenantID == expectedTenantID
            && responseIMUID == expectedIMUID
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

struct MyInviteCodePresentation: Equatable {
    let title: String
    let subtitle: String
    let displayCode: String
    let copyValue: String?
    let isUsableForRegistration: Bool
    let isWarning: Bool
    let shouldShowStats: Bool

    init(inviteCode: RemoteMyInviteCode?, isLoading: Bool, errorMessage: String?) {
        let code = inviteCode?.memberInviteCode.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usable = inviteCode?.isUsableForRegistration == true && !code.isEmpty
        displayCode = code
        isUsableForRegistration = usable
        copyValue = !isLoading && usable ? code : nil
        shouldShowStats = usable && inviteCode?.item != nil
        isWarning = !error.isEmpty || inviteCode?.isSyncFailed == true || (!code.isEmpty && !usable)

        if isLoading {
            title = "正在获取"
            subtitle = "正在读取当前企业邀请码"
        } else if !code.isEmpty {
            title = code
            if !error.isEmpty {
                subtitle = error
            } else if inviteCode?.isSyncFailed == true {
                subtitle = "邀请码暂不可用于注册"
            } else if usable {
                subtitle = "可分享给同企业成员注册"
            } else {
                subtitle = "邀请码当前不可用于注册"
            }
        } else if !error.isEmpty {
            title = "暂不可读取"
            subtitle = error
        } else {
            title = "暂不可用"
            subtitle = "当前角色暂无邀请码"
        }
    }
}

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteMemberInviteCodeItem = IM4Data.RemoteMemberInviteCodeItem
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteGroupInviteApprovalReviewResponse = IM4Data.RemoteGroupInviteApprovalReviewResponse

extension RemoteGroupInviteApprovalReviewResponse {
    func resolvedStatus(fallback: String) -> String {
        Self.firstNonEmpty(status, request?.status, alreadyProcessed ? "processed" : "", fallback)
    }

    func resolvedResultText(fallback: String) -> String {
        let explicit = Self.firstNonEmpty(resultText, request?.resultText, request?.reviewReason)
        if !explicit.isEmpty { return explicit }
        switch resolvedStatus(fallback: fallback).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved", "approve", "accepted", "pass", "passed":
            return "已通过"
        case "rejected", "reject", "denied", "declined", "refused":
            return "已拒绝"
        case "canceled", "cancelled", "cancel":
            return "已取消"
        case "expired", "expire", "timed_out", "timeout":
            return "已过期"
        case "processed":
            return "已处理"
        default:
            return fallback
        }
    }

    func resolvedApproverName(fallback: String) -> String {
        Self.firstNonEmpty(approverName, request?.approverName, fallback)
    }

    func resolvedApproverAccountID() -> String {
        Self.firstNonEmpty(approverAccountID, request?.approverAccountID)
    }

    func resolvedDecidedAt(fallback: String) -> String {
        Self.firstNonEmpty(decidedAt, request?.decidedAt, fallback)
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteGroupInviteApprovalReviewRequest = IM4Data.RemoteGroupInviteApprovalReviewRequest
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
