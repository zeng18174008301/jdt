// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_BEGIN
import Foundation

public struct APIEnvelope<T: Decodable>: Decodable {
    public let ok: Bool?
    public let data: T?
    public let error: APIEnvelopeError?

    public init(ok: Bool?, data: T?, error: APIEnvelopeError?) {
        self.ok = ok
        self.data = data
        self.error = error
    }
}

extension APIEnvelope: Sendable where T == RemoteConversationPage {}

public struct APILoginSecurityEnvelope: Decodable, Sendable { // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
    public let code: String?
    public let reasonCode: String?
    public let message: String?
    public let error: APIEnvelopeError?
    public let data: RemoteLoginSecurityInfo?

    enum CodingKeys: String, CodingKey {
        case code
        case reasonCode = "reason_code"
        case message
        case error
        case data
    }



    public init(code: String?, reasonCode: String?, message: String?, error: APIEnvelopeError?, data: RemoteLoginSecurityInfo?) {
        self.code = code
        self.reasonCode = reasonCode
        self.message = message
        self.error = error
        self.data = data
    }
}

public struct APIErrorEnvelope: Decodable, Sendable { // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
    public let ok: Bool?
    public let code: String?
    public let reasonCode: String?
    public let message: String?
    public let reason: String?
    public let error: APIEnvelopeError?
    public let data: APIEnvelopeError?

    enum CodingKeys: String, CodingKey {
        case ok
        case code
        case reasonCode = "reason_code"
        case message
        case reason
        case error
        case data
    }



    public init(ok: Bool?, code: String?, reasonCode: String?, message: String?, reason: String?, error: APIEnvelopeError?, data: APIEnvelopeError?) {
        self.ok = ok
        self.code = code
        self.reasonCode = reasonCode
        self.message = message
        self.reason = reason
        self.error = error
        self.data = data
    }
}

public struct APIEnvelopeError: Decodable, Sendable { // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
    public let code: String?
    public let reasonCode: String?
    public let message: String?
    public let reason: String?
    public let retryAfterSeconds: Int?
    public let lockedUntil: String?
    public let scope: String?
    public let tenantID: String?
    public let subjectType: String?
    public let blockType: String?
    public let status: String?
    public let expiresAt: String?
    public let remainingSeconds: Int?
    public let peerIMUID: String?
    public let peerUserID: String?
    public let targetUID: String?
    public let canApplyFriend: Bool?
    public let friendRequestStatus: String?
    public let friendAction: String?
    public let friendFlow: String?

    enum CodingKeys: String, CodingKey {
        case code
        case reasonCode = "reason_code"
        case message
        case reason
        case reasonText = "reason_text"
        case retryAfter = "retry_after"
        case retryAfterSeconds = "retry_after_seconds"
        case retryAfterCamel = "retryAfter"
        case lockedUntil = "locked_until"
        case lockedUntilCamel = "lockedUntil"
        case blockedUntil = "blocked_until"
        case banUntil = "ban_until"
        case scope
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case subjectType = "subject_type"
        case subjectTypeCamel = "subjectType"
        case reasonCodeCamel = "reasonCode"
        case blockType = "block_type"
        case blockTypeCamel = "blockType"
        case status
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
        case remainingSeconds = "remaining_seconds"
        case remainingSecondsCamel = "remainingSeconds"
        case peerIMUID = "peer_im_uid"
        case peerIMUIDCamel = "peerImUID"
        case peerUserID = "peer_user_id"
        case peerUserIDCamel = "peerUserID"
        case targetUID = "target_uid"
        case targetUIDCamel = "targetUID"
        case canApplyFriend = "can_apply_friend"
        case canApplyFriendCamel = "canApplyFriend"
        case friendRequestStatus = "friend_request_status"
        case friendRequestStatusCamel = "friendRequestStatus"
        case relationStatus = "relation_status"
        case relationStatusCamel = "relationStatus"
        case friendAction = "friend_action"
        case friendActionCamel = "friendAction"
        case friendFlow = "friend_flow"
        case friendFlowCamel = "friendFlow"
        case error
    }

    public init(
        code: String?,
        reasonCode: String? = nil,
        message: String?,
        reason: String? = nil,
        retryAfterSeconds: Int? = nil,
        lockedUntil: String? = nil,
        scope: String? = nil,
        tenantID: String? = nil,
        subjectType: String? = nil,
        blockType: String? = nil,
        status: String? = nil,
        expiresAt: String? = nil,
        remainingSeconds: Int? = nil,
        peerIMUID: String? = nil,
        peerUserID: String? = nil,
        targetUID: String? = nil,
        canApplyFriend: Bool? = nil,
        friendRequestStatus: String? = nil,
        friendAction: String? = nil,
        friendFlow: String? = nil
    ) {
        self.code = code
        self.reasonCode = reasonCode
        self.message = message
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
        self.lockedUntil = lockedUntil
        self.scope = scope
        self.tenantID = tenantID
        self.subjectType = subjectType
        self.blockType = blockType
        self.status = status
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.peerIMUID = peerIMUID
        self.peerUserID = peerUserID
        self.targetUID = targetUID
        self.canApplyFriend = canApplyFriend
        self.friendRequestStatus = friendRequestStatus
        self.friendAction = friendAction
        self.friendFlow = friendFlow
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            code = value
            reasonCode = nil
            message = value
            reason = nil
            retryAfterSeconds = nil
            lockedUntil = nil
            scope = nil
            tenantID = nil
            subjectType = nil
            blockType = nil
            status = nil
            expiresAt = nil
            remainingSeconds = nil
            peerIMUID = nil
            peerUserID = nil
            targetUID = nil
            canApplyFriend = nil
            friendRequestStatus = nil
            friendAction = nil
            friendFlow = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try c.decodeIfPresent(APIEnvelopeError.self, forKey: .error)
        let decodedReasonCode = try c.decodeIfPresent(String.self, forKey: .reasonCode)
            ?? c.decodeIfPresent(String.self, forKey: .reasonCodeCamel)
        reasonCode = decodedReasonCode ?? nested?.reasonCode
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? decodedReasonCode ?? nested?.code ?? nested?.reasonCode
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? nested?.message
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
            ?? c.decodeIfPresent(String.self, forKey: .reasonText)
            ?? nested?.reason
        let retryAfterValue = c.decodeLossyIntIfPresent(forKey: .retryAfter)
            ?? c.decodeLossyIntIfPresent(forKey: .retryAfterSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .retryAfterCamel)
            ?? nested?.retryAfterSeconds
        retryAfterSeconds = retryAfterValue
        lockedUntil = try c.decodeIfPresent(String.self, forKey: .lockedUntil)
            ?? c.decodeIfPresent(String.self, forKey: .lockedUntilCamel)
            ?? c.decodeIfPresent(String.self, forKey: .blockedUntil)
            ?? c.decodeIfPresent(String.self, forKey: .banUntil)
            ?? nested?.lockedUntil
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? nested?.scope
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? nested?.tenantID
        subjectType = try c.decodeIfPresent(String.self, forKey: .subjectType)
            ?? c.decodeIfPresent(String.self, forKey: .subjectTypeCamel)
            ?? nested?.subjectType
        blockType = try c.decodeIfPresent(String.self, forKey: .blockType)
            ?? c.decodeIfPresent(String.self, forKey: .blockTypeCamel)
            ?? nested?.blockType
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? nested?.status
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
            ?? c.decodeIfPresent(String.self, forKey: .expiresAtCamel)
            ?? nested?.expiresAt
        remainingSeconds = c.decodeLossyIntIfPresent(forKey: .remainingSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .remainingSecondsCamel)
            ?? nested?.remainingSeconds
        peerIMUID = try c.decodeIfPresent(String.self, forKey: .peerIMUID)
            ?? c.decodeIfPresent(String.self, forKey: .peerIMUIDCamel)
            ?? nested?.peerIMUID
        peerUserID = try c.decodeIfPresent(String.self, forKey: .peerUserID)
            ?? c.decodeIfPresent(String.self, forKey: .peerUserIDCamel)
            ?? nested?.peerUserID
        targetUID = try c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUIDCamel)
            ?? nested?.targetUID
        canApplyFriend = c.decodeLossyBoolIfPresent(forKey: .canApplyFriend)
            ?? c.decodeLossyBoolIfPresent(forKey: .canApplyFriendCamel)
            ?? nested?.canApplyFriend
        friendRequestStatus = try c.decodeIfPresent(String.self, forKey: .friendRequestStatus)
            ?? c.decodeIfPresent(String.self, forKey: .friendRequestStatusCamel)
            ?? c.decodeIfPresent(String.self, forKey: .relationStatus)
            ?? c.decodeIfPresent(String.self, forKey: .relationStatusCamel)
            ?? nested?.friendRequestStatus
        friendAction = try c.decodeIfPresent(String.self, forKey: .friendAction)
            ?? c.decodeIfPresent(String.self, forKey: .friendActionCamel)
            ?? nested?.friendAction
        friendFlow = try c.decodeIfPresent(String.self, forKey: .friendFlow)
            ?? c.decodeIfPresent(String.self, forKey: .friendFlowCamel)
            ?? nested?.friendFlow
    }
}

public struct RemoteList<T: Decodable>: Decodable {
    public let items: [T]
    public let selfMember: T?
    public let total: Int?
    public let limit: Int?
    public let offset: Int?
    public let hasMore: Bool?
    public let nextOffset: Int?
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case selfMember = "self_member"
        case selfMemberCamel = "selfMember"
        case total
        case totalCount = "total_count"
        case count
        case limit
        case offset
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case nextOffset = "next_offset"
        case nextOffsetCamel = "nextOffset"
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([T].self, forKey: .items) ?? []
        selfMember = try c.decodeIfPresent(T.self, forKey: .selfMember)
            ?? c.decodeIfPresent(T.self, forKey: .selfMemberCamel)
        total = Self.decodeFlexibleInt(from: c, keys: [.total, .totalCount, .count])
        limit = Self.decodeFlexibleInt(from: c, keys: [.limit])
        offset = Self.decodeFlexibleInt(from: c, keys: [.offset])
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
        nextOffset = Self.decodeFlexibleInt(from: c, keys: [.nextOffset, .nextOffsetCamel])
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }

    private static func decodeFlexibleInt(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

extension RemoteList: Sendable where T: Sendable {} // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111

public struct ConversationPageDecodedResponse: Sendable {
    public let errorEnvelope: APIErrorEnvelope?
    public let loginSecurityEnvelope: APILoginSecurityEnvelope?
    public let envelope: APIEnvelope<RemoteConversationPage>?

    public init(errorEnvelope: APIErrorEnvelope?, loginSecurityEnvelope: APILoginSecurityEnvelope?, envelope: APIEnvelope<RemoteConversationPage>?) {
        self.errorEnvelope = errorEnvelope
        self.loginSecurityEnvelope = loginSecurityEnvelope
        self.envelope = envelope
    }
}


// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_END
