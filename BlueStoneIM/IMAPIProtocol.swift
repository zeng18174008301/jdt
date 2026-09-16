import Foundation

struct RemotePhoneBindingChallenge: Equatable, Sendable {
    let requestID: String
    let sent: Bool
    let phoneMasked: String
    let expiresInSeconds: Int
    let cooldownSeconds: Int

    init(codeResult: RemotePhoneCodeResult) {
        requestID = codeResult.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        sent = codeResult.sent
        phoneMasked = codeResult.phoneMasked
        expiresInSeconds = codeResult.expiresInSeconds
        cooldownSeconds = codeResult.cooldownSeconds
    }
}

@MainActor
protocol IMAPIProtocol: AccessDiscoveryFetching, Sendable {
    var platformBase: URL { get }
    var tenantBase: URL { get }
    var imBase: URL { get }
    func login(username: String, password: String) async throws -> RemoteAuthData
    func refreshCurrentSession(context: IMAPIContext) async throws -> RemoteAuthSessionRefreshResult
    func refreshTenantIMSession(context: IMAPIContext, expiresInSeconds: Int?) async throws -> RemoteTenantIMSessionRefreshResult
    func logoutAuthSessions(context: IMAPIContext) async
    func webSocketURL(context: IMAPIContext) -> URL?
    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse
    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse
    func debugEndpointSummary(context: IMAPIContext) -> String
    func appBootstrap(appID: String, forceRefresh: Bool) async throws -> RemoteAppBootstrap
    func currentAppPolicy(appID: String, forceRefresh: Bool) async throws -> RemoteAppCurrentPolicy
    func resolveEnterpriseContext(tenantCode: String, appID: String, deviceID: String) async throws -> RemoteEnterpriseContextResult
    func publicLegalDocs(appID: String) async throws -> RemoteLegalDocManifest
    func resolveLegalDocAssetURL(_ rawValue: String, appID: String) async throws -> String
    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：协议正文由 API Origin 受控拉取，不交给外部浏览器二次请求
    func legalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
    func loginTenantUser(username: String, password: String, slideToken: String?, context: IMAPIContext) async throws -> RemoteTenantLoginData
    func loginIMUser(username: String, password: String, slideToken: String?, tenantCode: String, enterpriseContextToken: String, context: IMAPIContext) async throws -> RemoteTenantLoginData
    func slideCaptchaConfig(scene: String, surface: String, appID: String) async throws -> RemoteSlideCaptchaConfig
    func slideCaptchaChallenge(scene: String, surface: String) async throws -> RemoteSlideCaptchaChallenge
    func captchaEntryStatus(scene: String, channel: String, tenantCode: String, appID: String) async throws -> RemoteCaptchaEntryStatus
    func verifySlideCaptcha(_ request: SlideCaptchaVerifyRequest) async throws -> RemoteSlideCaptchaVerifyResult
    func resolveTenantAssetURL(_ rawValue: String) -> String
    func resolveTenantAssetURL(_ rawValue: String, context: IMAPIContext) -> String
    func register(username: String, phone: String, password: String, tenantCode: String?, captchaCode: String?, enterpriseContextToken: String?, appID: String, deviceID: String) async throws -> RemoteAuthData
    func registerWithRequestID(username: String, phone: String, password: String, tenantCode: String?, captchaCode: String?, enterpriseContextToken: String?, appID: String, deviceID: String, requestID: String, registrationSessionSecret: String?) async throws -> RemoteAuthData
    func registrationSession(appID: String, deviceID: String, requestID: String, secret: String) async throws -> RemoteRegistrationSessionResult
    func registrationStatus(appID: String, deviceID: String, requestID: String) async throws -> RemoteRegistrationStatus
    func resetPassword(phone: String, code: String, newPassword: String) async throws -> RemotePasswordResetResponse
    func sendPlatformCaptcha(phone: String, scene: String, tenantCode: String) async throws -> RemotePhoneCodeResult
    func sendTenantCaptcha(phone: String, scene: String, tenantCode: String, context: IMAPIContext) async throws -> RemotePhoneCodeResult
    func myTenantDirectory(platformToken: String?, appID: String) async throws -> RemoteTenantDirectoryResult
    func listMyTenants(platformToken: String?, appID: String) async throws -> [RemoteTenantMembership]
    func searchTenant(code: String, platformToken: String?, appID: String) async throws -> RemoteTenant
    func joinTenant(code: String, platformToken: String?, appID: String) async throws -> RemoteTenantMembership
    func resolveWorkspaceEntry(entryCode: String, platformToken: String?) async throws -> RemoteWorkspaceEntryState
    func prepareWorkspaceEntry(tenantID: String?, entryCode: String?, entrySource: String?, idempotencyKey: String?, platformToken: String?, context: IMAPIContext?) async throws -> RemoteWorkspaceEntryState
    func workspaceEntryStatus(tenantID: String, platformToken: String?, context: IMAPIContext?) async throws -> RemoteWorkspaceEntryState
    func enterTenant(tenantID: String, platformToken: String?, appID: String, deviceID: String) async throws -> RemoteTenantEnterResult
    func platformEntry(entryTicket: String, tenantBaseURL: URL, appID: String, deviceID: String) async throws -> RemoteTenantPlatformEntryResult
    func switchTenant(tenantID: String, platformToken: String?, appID: String, deviceID: String) async throws -> RemoteTenantSwitchResult
    func listWorkspaces(context: IMAPIContext) async throws -> [RemoteWorkspaceTenant]
    func searchWorkspaces(context: IMAPIContext, keyword: String) async throws -> [RemoteWorkspaceTenant]
    func joinWorkspace(context: IMAPIContext, tenantCode: String, reason: String) async throws -> RemoteWorkspaceJoinResult
    func switchWorkspace(context: IMAPIContext, tenantID: String, appID: String, deviceID: String) async throws -> RemoteWorkspaceSwitchResult
    func confirmWorkspaceEntry(context: IMAPIContext, tenantID: String) async throws -> RemoteDefaultWorkspaceResult
    func setDefaultWorkspace(platformToken: String?, tenantID: String) async throws -> RemoteDefaultWorkspaceResult
    func clearDefaultWorkspace(platformToken: String?) async throws -> RemoteDefaultWorkspaceResult
    func tenantContext(context: IMAPIContext) async throws -> RemoteTenantContext
    func tenantProfile(context: IMAPIContext) async throws -> RemoteTenantProfile
    func meProfile(context: IMAPIContext) async throws -> RemoteMeProfile
    func myInviteCode(context: IMAPIContext) async throws -> RemoteMyInviteCode
    func updateMeProfile(context: IMAPIContext, nickname: String?, username: String?) async throws -> RemoteMeProfile
    func changeMyPassword(context: IMAPIContext, currentPassword: String, newPassword: String) async throws -> RemotePasswordChangeResponse
    func cancelAccount(context: IMAPIContext, reason: String?) async throws -> RemoteAccountCancellationResponse
    func verificationStatus(context: IMAPIContext) async throws -> RemoteVerificationStatus
    func presignAvatarUpload(context: IMAPIContext, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData
    func uploadAvatarBinary(upload: RemoteSignedUpload, data: Data, mimeType: String) async throws
    func uploadGroupAvatarBinary(upload: RemoteSignedUpload, data: Data, mimeType: String) async throws
    func commitAvatar(context: IMAPIContext, fileID: String) async throws -> RemoteAvatarCommitData
    func presignFileUpload(context: IMAPIContext, conversation: Conversation, channelID: String, clientMessageID: String, purpose: String, fileName: String, mimeType: String, sizeBytes: Int) async throws -> RemoteAvatarUploadData
    func fileUploadConfig(context: IMAPIContext) async throws -> RemoteFileUploadConfig
    func uploadFileBinary(upload: RemoteSignedUpload, data: Data, mimeType: String, progress: (@Sendable (Double) -> Void)?) async throws
    func uploadFileBinary(upload: RemoteSignedUpload, fileURL: URL, mimeType: String, sizeBytes: Int64, progress: (@Sendable (Double) -> Void)?) async throws
    func markFileUploaded(context: IMAPIContext, fileID: String) async throws -> RemoteAvatarFile
    func markMessageFileUploaded(context: IMAPIContext, fileID: String, conversation: Conversation, channelID: String, clientMessageID: String) async throws -> RemoteAvatarFile
    func rtcProvider(context: IMAPIContext) async throws -> RemoteRTCProvider
    func listRTCCalls(context: IMAPIContext) async throws -> [RemoteRTCCall]
    func createRTCCall(context: IMAPIContext, calleeUID: String, callType: String, channelID: String?) async throws -> RemoteRTCCallResponse
    func acceptRTCCall(context: IMAPIContext, callID: String) async throws -> RemoteRTCCallResponse
    func rejectRTCCall(context: IMAPIContext, callID: String) async throws
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func rejectRTCCall(context: IMAPIContext, callID: String, idempotencyKey: String) async throws
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    func cancelRTCCall(context: IMAPIContext, callID: String, reason: String) async throws
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func cancelRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey: String) async throws
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    func hangupRTCCall(context: IMAPIContext, callID: String, reason: String) async throws
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func hangupRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey: String) async throws
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    func timeoutRTCCall(context: IMAPIContext, callID: String, reason: String) async throws
    func joinRTCRoom(context: IMAPIContext, roomID: String, rtcToken: String) async throws -> RemoteRTCRoomJoinData
    func updateRTCMediaState(
        context: IMAPIContext,
        callID: String,
        mediaState: String,
        expectedStateVersion: Int64?,
        idempotencyKey: String
    ) async throws -> RemoteRTCCall
    func listRTCRoomParticipants(context: IMAPIContext, roomID: String, rtcToken: String) async throws -> [RemoteRTCRoomParticipant]
    func postRTCSignal(context: IMAPIContext, roomID: String, rtcToken: String, envelope: RemoteRTCSignalEnvelope) async throws
    func pollRTCSignals(context: IMAPIContext, roomID: String, rtcToken: String, deviceID: String) async throws -> [RemoteRTCSignalItem]
    func updateRTCDeviceCapabilities(context: IMAPIContext, capabilities: RTCDeviceCapabilities) async throws
    func createRTCVideoCall(context: IMAPIContext, calleeUID: String, channelID: String?, capabilities: RTCDeviceCapabilities) async throws -> RemoteRTCCallResponse
    func acceptRTCCall(context: IMAPIContext, callID: String, mode: String, capabilities: RTCDeviceCapabilities) async throws -> RemoteRTCCallResponse
    func downgradeRTCCall(context: IMAPIContext, callID: String, reason: String) async throws -> RemoteRTCCallResponse
    func postRTCSignalV2(context: IMAPIContext, roomID: String, rtcToken: String, envelope: RemoteRTCSignalEnvelope) async throws -> RemoteRTCSignalPostResult
    func pollRTCSignalsV2(context: IMAPIContext, roomID: String, rtcToken: String, cursor: String, limit: Int, waitMS: Int) async throws -> RemoteRTCSignalItemsData
    func ackRTCSignals(context: IMAPIContext, roomID: String, rtcToken: String, cursor: String) async throws
    func refreshRTCIceCredentials(context: IMAPIContext, roomID: String, rtcToken: String) async throws -> RemoteRTCIceCredentials
    func postRTCQualitySamples(context: IMAPIContext, roomID: String, rtcToken: String, samples: [RTCQualitySample]) async throws -> RemoteRTCQualityBatchResult
    func listRTCCallEvents(context: IMAPIContext) async throws -> [RemoteRTCCallEvent]
    func ackRTCCallEventNotifications(context: IMAPIContext, notificationIDs: [String]) async throws
    func sendPhoneBindingCode(context: IMAPIContext, phone: String) async throws -> RemotePhoneCodeResult
    func sendPhoneBindingChallenge(context: IMAPIContext, phone: String) async throws -> RemotePhoneBindingChallenge
    func verifyPhoneBinding(context: IMAPIContext, phone: String, code: String) async throws -> RemoteIMUser
    func verifyPhoneBinding(context: IMAPIContext, phone: String, code: String, requestID: String) async throws -> RemoteIMUser
    func submitRealNameVerification(context: IMAPIContext, realName: String, idNumber: String) async throws -> RemoteVerificationStatus
    func registerDevice(context: IMAPIContext, registration: RemoteDeviceRegistration) async throws -> RemoteUserDevice
    func retireCurrentPushToken(context: IMAPIContext, provider: RemotePushTokenProvider, tokenFingerprint: String) async throws -> RemotePushTokenRetirementResponse
    func resolveNotificationTarget(context: IMAPIContext, targetRef: String) async throws -> RemoteNotificationTargetResolution
    func listDevices(context: IMAPIContext) async throws -> [RemoteUserDevice]
    func disableDevice(context: IMAPIContext, deviceID: String) async throws
    func listMyLoginLogs(context: IMAPIContext) async throws -> [RemoteMyLoginLog]
    func listFriends(context: IMAPIContext) async throws -> [RemoteFriendRelation]
    func friendRelationsForRemarkResolution(context: IMAPIContext) async throws -> [RemoteFriendRelation]
    func friendProfile(context: IMAPIContext, canonicalFriendUID: String) async throws -> RemoteFriendProfile
    func organizationTree(context: IMAPIContext) async throws -> RemoteOrganizationTree
    func organizationMembers(context: IMAPIContext, departmentID: String) async throws -> RemoteOrganizationMemberList
    func createOrganizationDepartment(context: IMAPIContext, parentDepartmentID: String, name: String) async throws -> RemoteDepartmentNode
    func updateOrganizationDepartment(context: IMAPIContext, departmentID: String, parentDepartmentID: String?, name: String?) async throws -> RemoteDepartmentNode
    func deleteOrganizationDepartment(context: IMAPIContext, departmentID: String) async throws
    func addOrganizationMember(context: IMAPIContext, departmentID: String, userID: String, isPrimary: Bool) async throws
    func removeOrganizationMember(context: IMAPIContext, departmentID: String, userID: String) async throws
    func listFriendApplications(context: IMAPIContext) async throws -> [RemoteFriendApplication]
    func searchTenantUsers(context: IMAPIContext, userID: String) async throws -> [RemoteUserSearchItem]
    func userProfiles(
        context: IMAPIContext,
        exactUIDs: [String]
    ) async throws -> RemoteUserProfilesResponse
    func tenantSearch(
        context: IMAPIContext,
        scope: String,
        query: String,
        types: [String],
        limit: Int,
        cursor: String?,
        typeCursors: [String: String],
        channelID: String?,
        channelType: String?,
        fromUID: String?,
        senderID: String?,
        startAt: String?,
        after: String?,
        endAt: String?,
        before: String?,
        fileType: String?,
        mimeType: String?,
        date: String?
    ) async throws -> RemoteTenantSearchResponse
    func postTenantSearchEvent(context: IMAPIContext, event: TenantSearchAnalyticsEvent) async throws
    func postRiskActivityEvents(context: IMAPIContext, events: [IOSRiskActivityEvent]) async throws -> IOSRiskActivityBatchResult
    func applyFriend(context: IMAPIContext, targetUID: String, message: String, source: String) async throws -> RemoteFriendApplyResult
    func acceptFriendApplication(context: IMAPIContext, id: String) async throws
    func rejectFriendApplication(context: IMAPIContext, id: String) async throws
    func cancelFriendApplication(context: IMAPIContext, id: String) async throws -> RemoteFriendApplication
    func deleteFriend(context: IMAPIContext, userID: String) async throws
    func updateFriendRemark(context: IMAPIContext, canonicalFriendUID: String, remark: String) async throws -> RemoteFriendProfile
    func listBlacklist(context: IMAPIContext) async throws -> [RemoteBlacklistRelation]
    func addBlacklist(context: IMAPIContext, userID: String, reason: String) async throws -> RemoteBlacklistRelation
    func deleteBlacklist(context: IMAPIContext, userID: String) async throws
    func listInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry]
    func listAnnouncementInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry]
    func markInboxRead(context: IMAPIContext, id: String) async throws
    func markSystemInboxRead(context: IMAPIContext) async throws -> RemoteSystemInboxReadResponse
    func reviewGroupInviteApproval(context: IMAPIContext, endpoint: String, reason: String) async throws -> RemoteGroupInviteApprovalReviewResponse
    func listGroups(context: IMAPIContext, scope: String) async throws -> [RemoteUserGroup]
    func createGroup(context: IMAPIContext, name: String, memberUIDs: [String]) async throws -> RemoteCreateGroupResponse
    func presignGroupAvatarUpload(context: IMAPIContext, groupID: String, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData
    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?) async throws -> RemoteGroupProfileUpdateResponse
    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?, expectedGroupRevision: Int64) async throws -> RemoteGroupProfileUpdateResponse
    func groupDetail(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDetail
    func groupSummary(context: IMAPIContext, groupID: String) async throws -> RemoteGroupSummary
    func leaveGroup(context: IMAPIContext, groupID: String, reason: String?) async throws -> RemoteGroupLeaveResult
    func previewDissolveGroup(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDissolvePreview
    func dissolveGroup(context: IMAPIContext, groupID: String, confirmed: Bool, reason: String?) async throws -> RemoteGroupDissolveResult
    func listGroupMembers(context: IMAPIContext, groupID: String) async throws -> RemoteGroupMembersResult
    func listGroupMembersPaged(context: IMAPIContext, groupID: String, limit: Int, offset: Int?, cursor: String?, keyword: String?, role: String?) async throws -> RemoteGroupMembersResult
    func searchGroupMembers(context: IMAPIContext, groupID: String, keyword: String) async throws -> RemoteGroupMembersResult
    func updateMyGroupNickname(context: IMAPIContext, groupID: String, groupNickname: String) async throws -> RemoteGroupMemberProfile
    func listGroupAnnouncements(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncementList
    func currentGroupAnnouncement(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncement?
    func groupAnnouncementDetail(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement
    func markGroupAnnouncementRead(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement
    func createGroupAnnouncement(context: IMAPIContext, groupID: String, title: String, content: String) async throws -> RemoteGroupAnnouncement
    func updateGroupAnnouncement(context: IMAPIContext, groupID: String, announcementID: String, title: String, content: String, expectedUpdatedAt: String) async throws -> RemoteGroupAnnouncement
    func listGroupFiles(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupFile]
    func listTenantFiles(context: IMAPIContext, query: String, category: String, limit: Int, offset: Int) async throws -> [RemoteGroupFile]
    func listFavoriteAssets(context: IMAPIContext, category: String, limit: Int, cursor: String) async throws -> RemoteFavoriteAssetsResponse
    func getTenantFile(context: IMAPIContext, fileID: String) async throws -> RemoteUserFileDetail
    func forwardTenantFile(context: IMAPIContext, fileID: String, targetChannelID: String, targetChannelType: String, clientMessageID: String) async throws -> RemoteMessage
    func listUserStickers(context: IMAPIContext, status: String?, since: String?, limit: Int?) async throws -> [RemoteUserSticker]
    func getUserSticker(context: IMAPIContext, id: String) async throws -> RemoteUserSticker
    func deleteUserSticker(context: IMAPIContext, id: String) async throws -> RemoteUserSticker
    func orderUserStickers(context: IMAPIContext, ids: [String]) async throws -> [RemoteUserSticker]
    func commitUserSticker(context: IMAPIContext, fileID: String, name: String?, packID: String?) async throws -> RemoteUserStickerCommitResult
    func listStickerPacks(context: IMAPIContext) async throws -> [RemoteStickerPack]
    func listStickerPackStickers(context: IMAPIContext, packID: String) async throws -> [RemoteSticker]
    func listGroupJoinRequests(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupJoinRequest]
    func createGroupJoinRequest(context: IMAPIContext, groupID: String, reason: String) async throws -> RemoteCreateGroupJoinRequestResponse
    func reviewGroupJoinRequest(context: IMAPIContext, groupID: String, requestID: String, approved: Bool) async throws -> RemoteGroupJoinRequest
    func updateGroupMute(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws -> RemoteGroupDetail
    func updateGroupMute(context: IMAPIContext, groupID: String, mode: GroupMuteMode, startAt: Date?, endAt: Date?) async throws -> RemoteGroupDetail
    func updateGroupMute(context: IMAPIContext, groupID: String, mode: GroupMuteMode, startAt: Date?, endAt: Date?, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail
    func updateGroupDND(context: IMAPIContext, groupID: String, muted: Bool) async throws -> RemoteGroupDetail
    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool) async throws -> RemoteGroupDetail
    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail
    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool) async throws -> RemoteGroupDetail
    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail
    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String) async throws -> RemoteGroupSettingsMutationResult
    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String, expectedGroupRevision: Int64) async throws -> RemoteGroupSettingsMutationResult
    func listGroupMuteList(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupMuteListItem]
    func addGroupMuteListMember(context: IMAPIContext, groupID: String, targetUID: String, reason: String) async throws -> RemoteGroupMuteListItem
    func removeGroupMuteListMember(context: IMAPIContext, groupID: String, uid: String) async throws
    func removeGroupMember(context: IMAPIContext, groupID: String, userID: String) async throws -> RemoteSearchInvalidationResponse
    func inviteGroupMembers(context: IMAPIContext, groupID: String, memberUIDs: [String]) async throws -> RemoteInviteGroupMembersResponse
    func updateGroupSettings(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws
    func updateGroupMemberRole(context: IMAPIContext, groupID: String, userID: String, role: String) async throws
    func transferGroupOwner(context: IMAPIContext, groupID: String, newOwnerUID: String, idempotencyKey: String) async throws -> RemoteGroupOwnerTransferResult
    func syncConversations(context: IMAPIContext, version: Int64) async throws -> RemoteConversationSyncData
    func conversationPage(context: IMAPIContext, cursor: String) async throws -> RemoteConversationPage
    func syncMessages(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, beforeSeq: Int64?, limit: Int) async throws -> RemoteMessageSyncResult
    func syncMessageReceipts(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, receiptType: String, limit: Int) async throws -> RemoteMessageReceiptSyncResult
    func syncMessageExtras(context: IMAPIContext, channelID: String, channelType: String, afterVersion: Int64, limit: Int) async throws -> [RemoteMessageExtra]
    func groupPinnedMessages(context: IMAPIContext, groupID: String, limit: Int) async throws -> [RemoteMessage]
    func searchMessages(context: IMAPIContext, conversation: Conversation, channelID: String, query: String, limit: Int) async throws -> [RemoteMessageSearchResult]
    func updateConversationSettings(context: IMAPIContext, conversation: Conversation, channelID: String) async throws
    func readAck(context: IMAPIContext, conversation: Conversation, channelID: String, throughSeq: Int64) async throws -> RemoteReadAckResponse
    func deliveryAck(context: IMAPIContext, conversation: Conversation, channelID: String, channelSeq: Int64) async throws
    func messageReadReceipts(context: IMAPIContext, messageID: String) async throws -> RemoteMessageReadReceiptResponse
    func sendText(context: IMAPIContext, conversation: Conversation, channelID: String, text: String, quote: String?, replyContext: MessageReplyContext?, clientMessageID: String, mentionAll: Bool, mentionedUsers: [MentionIdentity]) async throws -> RemoteMessage
    func sendAttachment(context: IMAPIContext, conversation: Conversation, channelID: String, kind: MessageKind, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, quote: String?, replyContext: MessageReplyContext?, clientMessageID: String) async throws -> RemoteMessage
    func sendVoice(context: IMAPIContext, conversation: Conversation, channelID: String, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, durationMS: Int, waveform: [Int], quote: String?, replyContext: MessageReplyContext?, clientMessageID: String) async throws -> RemoteMessage
    func sendSticker(context: IMAPIContext, conversation: Conversation, channelID: String, sticker: StickerMessageSnapshot, quote: String?, replyContext: MessageReplyContext?, clientMessageID: String) async throws -> RemoteMessage
    func sendContactCard(context: IMAPIContext, conversation: Conversation, channelID: String, contactID: String, contactName: String, contactAvatar: String?, quote: String?, clientMessageID: String) async throws -> RemoteMessage
	func editMessage(context: IMAPIContext, messageID: String, text: String, clientEditID: String, expectedEditRevision: Int64) async throws -> RemoteExtraResponse
    func recallMessage(context: IMAPIContext, messageID: String) async throws
    func adminDeleteGroupMessage(context: IMAPIContext, groupID: String, messageID: String) async throws
    func reactMessage(context: IMAPIContext, messageID: String, emoji: String, action: String) async throws -> RemoteExtraResponse
    func pinMessage(context: IMAPIContext, messageID: String, pinned: Bool) async throws -> RemoteExtraResponse
    func favoriteMessage(context: IMAPIContext, messageID: String, favorited: Bool) async throws
    func forwardMessage(context: IMAPIContext, messageID: String, targetChannelID: String, targetChannelType: String, clientMessageID: String) async throws -> RemoteMessage
    func forwardBatch(context: IMAPIContext, command: BatchForwardSubmitCommand) async throws -> BatchForwardCommittedResult
    func lookupMessageReport(context: IMAPIContext, messageID: String) async throws -> RemoteMessageReportLookupResponse
    func reportMessage(context: IMAPIContext, messageID: String, channelID: String, channelType: String, reason: String, description: String) async throws -> RemoteMessageReport
}

extension IMAPIProtocol {

func registrationSession(appID: String, deviceID: String, requestID: String, secret: String) async throws -> RemoteRegistrationSessionResult {
    throw IMAPIError.server("当前接口未实现注册会话恢复")
}


func registrationStatus(appID: String, deviceID: String, requestID: String) async throws -> RemoteRegistrationStatus {
    throw IMAPIError.server("当前接口未实现注册状态确认")
}

func disableDevice(context: IMAPIContext, deviceID: String) async throws {}

func retireCurrentPushToken(context: IMAPIContext, provider: RemotePushTokenProvider, tokenFingerprint: String) async throws -> RemotePushTokenRetirementResponse {
    throw IMAPIError.server("当前接口未实现推送令牌槽清理")
}

func resolveNotificationTarget(context: IMAPIContext, targetRef: String) async throws -> RemoteNotificationTargetResolution {
    throw IMAPIError.server("当前接口未实现通知目标解析")
}

func listMyLoginLogs(context: IMAPIContext) async throws -> [RemoteMyLoginLog] {
    []
}

func resolveEnterpriseContext(tenantCode: String, appID: String, deviceID: String) async throws -> RemoteEnterpriseContextResult {
    throw IMAPIError.server("当前接口未实现企业码上下文解析")
}

func resetPassword(phone: String, code: String, newPassword: String) async throws -> RemotePasswordResetResponse {
    throw IMAPIError.server("当前接口未实现密码重置")
}

func forwardTenantFile(context: IMAPIContext, fileID: String, targetChannelID: String, targetChannelType: String, clientMessageID: String) async throws -> RemoteMessage {
    throw IMAPIError.server("当前接口未实现文件转发")
}

func deliveryAck(context: IMAPIContext, conversation: Conversation, channelID: String, channelSeq: Int64) async throws {
    throw IMAPIError.server("当前接口未实现送达确认")
}

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
func rejectRTCCall(context: IMAPIContext, callID: String, idempotencyKey _: String) async throws {
    try await rejectRTCCall(context: context, callID: callID)
}

func cancelRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey _: String) async throws {
    try await cancelRTCCall(context: context, callID: callID, reason: reason)
}

func hangupRTCCall(context: IMAPIContext, callID: String, reason: String, idempotencyKey _: String) async throws {
    try await hangupRTCCall(context: context, callID: callID, reason: reason)
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

func ackRTCCallEventNotifications(context: IMAPIContext, notificationIDs: [String]) async throws {}

func resolveTenantAssetURL(_ rawValue: String, context: IMAPIContext) -> String {
    return self.resolveTenantAssetURL(rawValue)
}

func resolveLegalDocAssetURL(_ rawValue: String, appID: String) async throws -> String {
    return self.resolveTenantAssetURL(rawValue)
}

// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：默认实现保持协议兼容，真实实现由 IMAPIClient 提供
func legalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent {
    _ = type
    _ = appID
    _ = context
    throw IMAPIError.server("当前接口未实现协议正文读取")
}
// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

func listAnnouncementInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry] {
    return try await self.listInbox(context: context)
}

func currentAppPolicy(appID: String) async throws -> RemoteAppCurrentPolicy {
    return try await self.currentAppPolicy(appID: appID, forceRefresh: false)
}

func appBootstrap(appID: String) async throws -> RemoteAppBootstrap {
    return try await self.appBootstrap(appID: appID, forceRefresh: false)
}

func postRTCQualitySamples(
    context: IMAPIContext,
    roomID: String,
    rtcToken: String,
    samples: [RTCQualitySample]
) async throws -> RemoteRTCQualityBatchResult {
    throw IMAPIError.server("当前接口未实现 RTC 质量样本上报")
}

func captchaEntryStatus(scene: String, channel: String, tenantCode: String = "", appID: String) async throws -> RemoteCaptchaEntryStatus {
    return try await self.captchaEntryStatus(scene: scene, channel: channel, tenantCode: tenantCode, appID: appID)
}

func sendPlatformCaptcha(phone: String, scene: String, tenantCode: String = "") async throws -> RemotePhoneCodeResult {
    return try await self.sendPlatformCaptcha(phone: phone, scene: scene, tenantCode: tenantCode)
}

func sendTenantCaptcha(phone: String, scene: String, tenantCode: String = "", context: IMAPIContext) async throws -> RemotePhoneCodeResult {
    return try await self.sendTenantCaptcha(phone: phone, scene: scene, tenantCode: tenantCode, context: context)
}

func sendPhoneBindingChallenge(context: IMAPIContext, phone: String) async throws -> RemotePhoneBindingChallenge {
    let challenge = RemotePhoneBindingChallenge(
        codeResult: try await self.sendPhoneBindingCode(context: context, phone: phone)
    )
    guard challenge.sent, !challenge.requestID.isEmpty else {
        throw IMAPIError.businessForbidden(
            code: "phone_binding_request_id_missing",
            message: "手机号验证请求标识缺失，请重新获取验证码",
            error: nil
        )
    }
    return challenge
}

func verifyPhoneBinding(context: IMAPIContext, phone: String, code: String, requestID: String) async throws -> RemoteIMUser {
    throw IMAPIError.businessForbidden(
        code: "phone_binding_request_id_unsupported",
        message: "当前客户端无法安全提交手机号验证请求，请重新登录后重试",
        error: nil
    )
}

func prepareWorkspaceEntry(tenantID: String?, entryCode: String?, entrySource: String?, idempotencyKey: String?, platformToken: String?) async throws -> RemoteWorkspaceEntryState {
    return try await self.prepareWorkspaceEntry(tenantID: tenantID, entryCode: entryCode, entrySource: entrySource, idempotencyKey: idempotencyKey, platformToken: platformToken, context: nil)
}

func workspaceEntryStatus(tenantID: String, platformToken: String?) async throws -> RemoteWorkspaceEntryState {
    return try await self.workspaceEntryStatus(tenantID: tenantID, platformToken: platformToken, context: nil)
}

func joinWorkspace(context: IMAPIContext, tenantCode: String, reason: String = "") async throws -> RemoteWorkspaceJoinResult {
    return try await self.joinWorkspace(context: context, tenantCode: tenantCode, reason: reason)
}

func uploadFileBinary(upload: RemoteSignedUpload, data: Data, mimeType: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
    try await self.uploadFileBinary(upload: upload, data: data, mimeType: mimeType, progress: progress)
}

func uploadFileBinary(upload: RemoteSignedUpload, fileURL: URL, mimeType: String, sizeBytes: Int64, progress: (@Sendable (Double) -> Void)? = nil) async throws {
    _ = upload
    _ = fileURL
    _ = mimeType
    _ = sizeBytes
    _ = progress
    throw IMAPIError.server("file_upload_streaming_unavailable")
}

func createRTCCall(context: IMAPIContext, calleeUID: String, callType: String, channelID: String? = nil) async throws -> RemoteRTCCallResponse {
    return try await self.createRTCCall(context: context, calleeUID: calleeUID, callType: callType, channelID: channelID)
}

func registerDevice(context: IMAPIContext) async throws -> RemoteUserDevice {
    return try await self.registerDevice(context: context, registration: .standardIOS())
}

func reviewGroupInviteApproval(context: IMAPIContext, endpoint: String, reason: String = "") async throws -> RemoteGroupInviteApprovalReviewResponse {
    return try await self.reviewGroupInviteApproval(context: context, endpoint: endpoint, reason: reason)
}

func listTenantFiles(context: IMAPIContext, query: String = "", category: String = "", limit: Int = 100, offset: Int = 0) async throws -> [RemoteGroupFile] {
    return try await self.listTenantFiles(context: context, query: query, category: category, limit: limit, offset: offset)
}

func listFavoriteAssets(context: IMAPIContext, category: String = "all", limit: Int = 30, cursor: String = "") async throws -> RemoteFavoriteAssetsResponse {
    return try await self.listFavoriteAssets(context: context, category: category, limit: limit, cursor: cursor)
}

func listGroupMembersPaged(context: IMAPIContext, groupID: String, limit: Int, offset: Int? = nil, cursor: String? = nil, keyword: String? = nil, role: String? = nil) async throws -> RemoteGroupMembersResult {
    return try await self.listGroupMembersPaged(context: context, groupID: groupID, limit: limit, offset: offset, cursor: cursor, keyword: keyword, role: role)
}

func listUserStickers(context: IMAPIContext, status: String? = nil, since: String? = nil, limit: Int? = nil) async throws -> [RemoteUserSticker] {
    return try await self.listUserStickers(context: context, status: status, since: since, limit: limit)
}

func commitUserSticker(context: IMAPIContext, fileID: String, name: String? = nil, packID: String? = nil) async throws -> RemoteUserStickerCommitResult {
    return try await self.commitUserSticker(context: context, fileID: fileID, name: name, packID: packID)
}

func createGroupJoinRequest(context: IMAPIContext, groupID: String, reason: String = "") async throws -> RemoteCreateGroupJoinRequestResponse {
    return try await self.createGroupJoinRequest(context: context, groupID: groupID, reason: reason)
}

func updateGroupMute(
    context: IMAPIContext,
    groupID: String,
    mode: GroupMuteMode,
    startAt: Date? = nil,
    endAt: Date? = nil
) async throws -> RemoteGroupDetail {
    let state = try GroupMuteModeState.normalize(
        GroupMuteModeIntent(
            allMuted: mode != .off,
            mode: mode,
            startAt: startAt,
            endAt: endAt
        )
    )
    return try await self.updateGroupMute(
        context: context,
        groupID: groupID,
        allMuted: state.allMuted,
        startAt: state.startAt,
        endAt: state.endAt
    )
}

func syncMessages(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, limit: Int = 50) async throws -> RemoteMessageSyncResult {
    return try await self.syncMessages(context: context, channelID: channelID, channelType: channelType, afterSeq: afterSeq, beforeSeq: nil, limit: limit)
}

func syncMessagesBefore(context: IMAPIContext, channelID: String, channelType: String, beforeSeq: Int64, limit: Int = 50) async throws -> RemoteMessageSyncResult {
    return try await self.syncMessages(context: context, channelID: channelID, channelType: channelType, afterSeq: 0, beforeSeq: beforeSeq, limit: limit)
}

func syncMessageReceipts(context: IMAPIContext, channelID: String, channelType: String, afterSeq: Int64, receiptType: String, limit: Int = 100) async throws -> RemoteMessageReceiptSyncResult {
    return try await self.syncMessageReceipts(context: context, channelID: channelID, channelType: channelType, afterSeq: afterSeq, receiptType: receiptType, limit: limit)
}

func syncMessageExtras(context: IMAPIContext, channelID: String, channelType: String, afterVersion: Int64 = 0, limit: Int = 100) async throws -> [RemoteMessageExtra] {
    return try await self.syncMessageExtras(context: context, channelID: channelID, channelType: channelType, afterVersion: afterVersion, limit: limit)
}

func groupPinnedMessages(context: IMAPIContext, groupID: String, limit: Int = 50) async throws -> [RemoteMessage] {
    return try await self.groupPinnedMessages(context: context, groupID: groupID, limit: limit)
}

func searchMessages(context: IMAPIContext, conversation: Conversation, channelID: String, query: String, limit: Int = 50) async throws -> [RemoteMessageSearchResult] {
    return try await self.searchMessages(context: context, conversation: conversation, channelID: channelID, query: query, limit: limit)
}

func tenantSearch(
    context: IMAPIContext,
    scope: String,
    query: String,
    types: [String],
    limit: Int,
    cursor: String? = nil,
    typeCursors: [String: String] = [:],
    channelID: String? = nil,
    channelType: String? = nil,
    fromUID: String? = nil,
    senderID: String? = nil,
    startAt: String? = nil,
    after: String? = nil,
    endAt: String? = nil,
    before: String? = nil,
    fileType: String? = nil,
    mimeType: String? = nil,
    date: String? = nil
) async throws -> RemoteTenantSearchResponse {
    try await self.tenantSearch(
        context: context,
        scope: scope,
        query: query,
        types: types,
        limit: limit,
        cursor: cursor,
        typeCursors: typeCursors,
        channelID: channelID,
        channelType: channelType,
        fromUID: fromUID,
        senderID: senderID,
        startAt: startAt,
        after: after,
        endAt: endAt,
        before: before,
        fileType: fileType,
        mimeType: mimeType,
        date: date
    )
}

func sendText(context: IMAPIContext, conversation: Conversation, channelID: String, text: String, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String, mentionAll: Bool = false, mentionedUsers: [MentionIdentity] = []) async throws -> RemoteMessage {
    return try await self.sendText(context: context, conversation: conversation, channelID: channelID, text: text, quote: quote, replyContext: replyContext, clientMessageID: clientMessageID, mentionAll: mentionAll, mentionedUsers: mentionedUsers)
}

func sendAttachment(context: IMAPIContext, conversation: Conversation, channelID: String, kind: MessageKind, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
    return try await self.sendAttachment(context: context, conversation: conversation, channelID: channelID, kind: kind, file: file, name: name, mimeType: mimeType, sizeBytes: sizeBytes, quote: quote, replyContext: replyContext, clientMessageID: clientMessageID)
}

func sendVoice(context: IMAPIContext, conversation: Conversation, channelID: String, file: RemoteAvatarFile, name: String, mimeType: String, sizeBytes: Int64?, durationMS: Int, waveform: [Int], quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
    return try await self.sendVoice(context: context, conversation: conversation, channelID: channelID, file: file, name: name, mimeType: mimeType, sizeBytes: sizeBytes, durationMS: durationMS, waveform: waveform, quote: quote, replyContext: replyContext, clientMessageID: clientMessageID)
}

func sendSticker(context: IMAPIContext, conversation: Conversation, channelID: String, sticker: StickerMessageSnapshot, quote: String?, replyContext: MessageReplyContext? = nil, clientMessageID: String) async throws -> RemoteMessage {
    return try await self.sendSticker(context: context, conversation: conversation, channelID: channelID, sticker: sticker, quote: quote, replyContext: replyContext, clientMessageID: clientMessageID)
}

func reportMessage(context: IMAPIContext, messageID: String, channelID: String, channelType: String, reason: String) async throws -> RemoteMessageReport {
    try await self.reportMessage(context: context, messageID: messageID, channelID: channelID, channelType: channelType, reason: reason, description: reason)
}
}
