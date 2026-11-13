import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteMyInviteCode: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let status: String
    public let reasonCode: String
    public let item: RemoteMemberInviteCodeItem?

    enum CodingKeys: String, CodingKey {
        case enabled
        case status
        case reasonCode = "reason_code"
        case reasonCodeCamel = "reasonCode"
        case item
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decodeLossyBoolIfPresent(forKey: .enabled) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? Self.itemStatusFallback(from: c)
        reasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .reasonCodeCamel)
            ?? ""
        item = try c.decodeIfPresent(RemoteMemberInviteCodeItem.self, forKey: .item)
    }

    private static func itemStatusFallback(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        guard let item = try? container.decodeIfPresent(RemoteMemberInviteCodeItem.self, forKey: .item) else {
            return ""
        }
        return item.status
    }

    public init(
        enabled: Bool,
        status: String,
        reasonCode: String,
        item: RemoteMemberInviteCodeItem?
    ) {
        self.enabled = enabled
        self.status = status
        self.reasonCode = reasonCode
        self.item = item
    }
}

public struct RemoteMemberInviteCodeItem: Decodable, Equatable, Sendable {
    public let id: String
    public let tenantID: String
    public let imUID: String
    public let userID: String
    public let displayName: String
    public let role: String
    public let memberInviteCode: String
    public let status: String
    public let syncStatus: String
    public let syncErrorCode: String
    public let syncVersion: Int
    public let inviteCount: Int
    public let joinedCount: Int
    public let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case userID = "user_id"
        case userIDCamel = "userID"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case role
        case memberInviteCode = "member_invite_code"
        case status
        case syncStatus = "sync_status"
        case syncStatusCamel = "syncStatus"
        case syncErrorCode = "sync_error_code"
        case syncErrorCodeCamel = "syncErrorCode"
        case syncVersion = "sync_version"
        case syncVersionCamel = "syncVersion"
        case inviteCount = "invite_count"
        case inviteCountCamel = "inviteCount"
        case joinedCount = "joined_count"
        case joinedCountCamel = "joinedCount"
        case pendingCount = "pending_count"
        case pendingCountCamel = "pendingCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
            ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
            ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
            ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        memberInviteCode = try c.decodeIfPresent(String.self, forKey: .memberInviteCode) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
            ?? c.decodeIfPresent(String.self, forKey: .syncStatusCamel)
            ?? ""
        syncErrorCode = try c.decodeIfPresent(String.self, forKey: .syncErrorCode)
            ?? c.decodeIfPresent(String.self, forKey: .syncErrorCodeCamel)
            ?? ""
        syncVersion = c.decodeLossyIntIfPresent(forKey: .syncVersion)
            ?? c.decodeLossyIntIfPresent(forKey: .syncVersionCamel)
            ?? 0
        inviteCount = c.decodeLossyIntIfPresent(forKey: .inviteCount)
            ?? c.decodeLossyIntIfPresent(forKey: .inviteCountCamel)
            ?? 0
        joinedCount = c.decodeLossyIntIfPresent(forKey: .joinedCount)
            ?? c.decodeLossyIntIfPresent(forKey: .joinedCountCamel)
            ?? 0
        pendingCount = c.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingCountCamel)
            ?? 0
    }

    public init(
        id: String,
        tenantID: String,
        imUID: String,
        userID: String,
        displayName: String,
        role: String,
        memberInviteCode: String,
        status: String,
        syncStatus: String,
        syncErrorCode: String,
        syncVersion: Int,
        inviteCount: Int,
        joinedCount: Int,
        pendingCount: Int
    ) {
        self.id = id
        self.tenantID = tenantID
        self.imUID = imUID
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.memberInviteCode = memberInviteCode
        self.status = status
        self.syncStatus = syncStatus
        self.syncErrorCode = syncErrorCode
        self.syncVersion = syncVersion
        self.inviteCount = inviteCount
        self.joinedCount = joinedCount
        self.pendingCount = pendingCount
    }
}

public struct RemoteGroupInviteApprovalReviewResponse: Decodable, Sendable {
    public let request: RemoteGroupInviteApprovalReviewRequest?
    public let status: String
    public let resultText: String
    public let approverName: String
    public let approverAccountID: String
    public let decidedAt: String
    public let alreadyProcessed: Bool

    enum CodingKeys: String, CodingKey {
        case request
        case status
        case requestStatus = "request_status"
        case approvalStatus = "approval_status"
        case resultText = "result_text"
        case result
        case message
        case approverName = "approver_name"
        case decidedByName = "decided_by_name"
        case reviewedByName = "reviewed_by_name"
        case reviewerName = "reviewer_name"
        case approverAccountID = "approver_account_id"
        case approverUID = "approver_uid"
        case decidedByUID = "decided_by_uid"
        case reviewedBy = "reviewed_by"
        case reviewerUID = "reviewer_uid"
        case decidedAt = "decided_at"
        case reviewedAt = "reviewed_at"
        case processedAt = "processed_at"
        case alreadyProcessed = "already_processed"
        case processed
    }

    public init() {
        request = nil
        status = ""
        resultText = ""
        approverName = ""
        approverAccountID = ""
        decidedAt = ""
        alreadyProcessed = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = try c.decodeIfPresent(RemoteGroupInviteApprovalReviewRequest.self, forKey: .request)
        status = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .status),
            try c.decodeIfPresent(String.self, forKey: .requestStatus),
            try c.decodeIfPresent(String.self, forKey: .approvalStatus)
        )
        resultText = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .resultText),
            try c.decodeIfPresent(String.self, forKey: .result),
            try c.decodeIfPresent(String.self, forKey: .message)
        )
        approverName = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverName),
            try c.decodeIfPresent(String.self, forKey: .decidedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewerName)
        )
        approverAccountID = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverAccountID),
            try c.decodeIfPresent(String.self, forKey: .approverUID),
            try c.decodeIfPresent(String.self, forKey: .decidedByUID),
            try c.decodeIfPresent(String.self, forKey: .reviewedBy),
            try c.decodeIfPresent(String.self, forKey: .reviewerUID)
        )
        decidedAt = Self.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .decidedAt),
            try c.decodeIfPresent(String.self, forKey: .reviewedAt),
            try c.decodeIfPresent(String.self, forKey: .processedAt)
        )
        alreadyProcessed = c.decodeLossyBoolIfPresent(forKey: .alreadyProcessed)
            ?? c.decodeLossyBoolIfPresent(forKey: .processed)
            ?? false
    }











    public static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}

public struct RemoteGroupInviteApprovalReviewRequest: Decodable, Sendable {
    public let status: String
    public let resultText: String
    public let reviewReason: String
    public let approverName: String
    public let approverAccountID: String
    public let decidedAt: String

    enum CodingKeys: String, CodingKey {
        case status
        case requestStatus = "request_status"
        case approvalStatus = "approval_status"
        case resultText = "result_text"
        case result
        case reviewReason = "review_reason"
        case approverName = "approver_name"
        case decidedByName = "decided_by_name"
        case reviewedByName = "reviewed_by_name"
        case reviewerName = "reviewer_name"
        case approverAccountID = "approver_account_id"
        case approverUID = "approver_uid"
        case decidedByUID = "decided_by_uid"
        case reviewedBy = "reviewed_by"
        case reviewerUID = "reviewer_uid"
        case decidedAt = "decided_at"
        case reviewedAt = "reviewed_at"
        case processedAt = "processed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .status),
            try c.decodeIfPresent(String.self, forKey: .requestStatus),
            try c.decodeIfPresent(String.self, forKey: .approvalStatus)
        )
        resultText = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .resultText),
            try c.decodeIfPresent(String.self, forKey: .result)
        )
        reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason) ?? ""
        approverName = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverName),
            try c.decodeIfPresent(String.self, forKey: .decidedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewedByName),
            try c.decodeIfPresent(String.self, forKey: .reviewerName)
        )
        approverAccountID = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .approverAccountID),
            try c.decodeIfPresent(String.self, forKey: .approverUID),
            try c.decodeIfPresent(String.self, forKey: .decidedByUID),
            try c.decodeIfPresent(String.self, forKey: .reviewedBy),
            try c.decodeIfPresent(String.self, forKey: .reviewerUID)
        )
        decidedAt = RemoteGroupInviteApprovalReviewResponse.firstNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .decidedAt),
            try c.decodeIfPresent(String.self, forKey: .reviewedAt),
            try c.decodeIfPresent(String.self, forKey: .processedAt)
        )
    }

    public init(
        status: String,
        resultText: String,
        reviewReason: String,
        approverName: String,
        approverAccountID: String,
        decidedAt: String
    ) {
        self.status = status
        self.resultText = resultText
        self.reviewReason = reviewReason
        self.approverName = approverName
        self.approverAccountID = approverAccountID
        self.decidedAt = decidedAt
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
