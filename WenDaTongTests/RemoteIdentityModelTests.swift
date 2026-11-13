import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteFriendRelationDecodesRemarkDisplayFieldsSeparately() throws {
        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-remarked",
          "friend_user_id": "WXT000003",
          "friend_nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总"
        }
        """.utf8))

        XCTAssertEqual(relation.friendNickname, "原始昵称")
        XCTAssertEqual(relation.rawNickname, "原始昵称")
        XCTAssertEqual(relation.displayName, "客户王总")
        XCTAssertEqual(relation.displayNameSource, "remark")
        XCTAssertEqual(relation.remark, "客户王总")
    }

    func testRemoteUserSearchItemDecodesRemarkDisplayFieldsSeparately() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "u-search",
          "user_id": "WXT000004",
          "nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总"
        }
        """.utf8))

        XCTAssertEqual(item.nickname, "原始昵称")
        XCTAssertEqual(item.rawNickname, "原始昵称")
        XCTAssertEqual(item.displayName, "客户王总")
        XCTAssertEqual(item.displayNameSource, "remark")
        XCTAssertEqual(item.remark, "客户王总")
    }

    func testRemoteUserSearchItemDecodesFriendRelationV2Contract() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "internal-1",
          "user_id": "WXTAB123456",
          "nickname": "内部用户",
          "relation_status": "none",
          "can_apply_friend": true,
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))

        XCTAssertEqual(item.relationStatus, "none")
        XCTAssertTrue(item.canApplyFriend)
        XCTAssertEqual(item.friendAction, "request")
        XCTAssertEqual(item.friendFlow, "ordinary_to_internal")
        XCTAssertEqual(item.requiresTenantReview, false)
        XCTAssertEqual(item.requiresTargetApproval, false)
    }

    func testRemoteUserSearchItemLegacyResponseDerivesFriendAction() throws {
        let item = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "legacy-1",
          "user_id": "WXT00000001",
          "nickname": "旧服务端用户",
          "can_apply_friend": true
        }
        """.utf8))

        XCTAssertEqual(item.friendAction, "request")
        XCTAssertEqual(item.friendFlow, "")
        XCTAssertNil(item.requiresTenantReview)
        XCTAssertNil(item.requiresTargetApproval)
    }

    func testRemoteFriendApplyResultDecodesSuppressedAndEstablishedOutcomes() throws {
        let suppressed = try JSONDecoder().decode(RemoteFriendApplyResult.self, from: Data("""
        {
          "application_id": "application-1",
          "status": "suppressed",
          "outcome": "application_suppressed",
          "relation_status": "history",
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "directly_established": false,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))
        let established = try JSONDecoder().decode(RemoteFriendApplyResult.self, from: Data("""
        {
          "id": "relation-1",
          "status": "accepted",
          "outcome": "friendship_established",
          "relation_status": "friend",
          "friend_action": "direct_add",
          "friend_flow": "internal_direct",
          "directly_established": true,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))

        XCTAssertEqual(suppressed.id, "application-1")
        XCTAssertEqual(suppressed.outcome, "application_suppressed")
        XCTAssertEqual(suppressed.friendFlow, "ordinary_to_internal")
        XCTAssertFalse(suppressed.directlyEstablished)
        XCTAssertEqual(suppressed.relationStatus, "history")
        XCTAssertEqual(AppState.friendApplyResolution(suppressed), .terminal)
        XCTAssertEqual(established.outcome, "friendship_established")
        XCTAssertEqual(established.relationStatus, "friend")
        XCTAssertEqual(established.friendAction, "direct_add")
        XCTAssertTrue(established.directlyEstablished)
        XCTAssertEqual(AppState.friendApplyResolution(established), .established)
    }

    func testRemoteFriendApplicationAndErrorDecodeV2FriendMetadata() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-2",
          "applicant_uid": "ordinary-1",
          "target_uid": "internal-1",
          "status": "suppressed",
          "direction": "outgoing",
          "outcome": "application_suppressed",
          "relation_status": "history",
          "friend_action": "request",
          "friend_flow": "ordinary_to_internal",
          "directly_established": false,
          "requires_tenant_review": false,
          "requires_target_approval": false
        }
        """.utf8))
        let error = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data("""
        {
          "ok": false,
          "code": "not_friends",
          "data": {
            "target_uid": "ordinary-2",
            "can_apply_friend": true,
            "relation_status": "none",
            "friend_action": "request",
            "friend_flow": "internal_direct"
          }
        }
        """.utf8))

        XCTAssertEqual(application.outcome, "application_suppressed")
        let projected = try XCTUnwrap(AppState.friendRequestProjection(application, currentID: "ordinary-1"))
        XCTAssertEqual(projected.status, "suppressed")
        XCTAssertEqual(projected.relationStatus, "history")
        XCTAssertEqual(projected.message, FriendAddPresentation.suppressedMessage)
        XCTAssertEqual(projected.statusLabel, "未投递")
        XCTAssertFalse(projected.isPendingOutgoing)
        XCTAssertFalse(projected.canCancel)
        XCTAssertFalse(projected.accepted)
        XCTAssertEqual(application.friendFlow, "ordinary_to_internal")
        XCTAssertEqual(application.requiresTargetApproval, false)
        XCTAssertEqual(error.resolvedError?.friendRequestStatus, "none")
        XCTAssertEqual(error.resolvedError?.friendAction, "request")
        XCTAssertEqual(error.resolvedError?.friendFlow, "internal_direct")
    }

    func testFriendProjectionTrustsViewerActionableAndServerDirectionOverGenericHints() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-actionable",
          "applicant_uid": "ordinary-peer",
          "target_uid": "internal-current",
          "applicant_name": "申请人",
          "status": "pending",
          "direction": "incoming",
          "actionable_by_current_user": true,
          "tenant_review_status": "not_required",
          "requires_target_approval": false
        }
        """.utf8))

        let projected = try XCTUnwrap(
            AppState.friendRequestProjection(application, currentID: "internal-current")
        )
        XCTAssertEqual(projected.direction, "incoming")
        XCTAssertTrue(projected.canRespond)
        XCTAssertTrue(projected.isPendingIncoming)
    }

    func testFriendProjectionUsesIdentityDirectionOnlyForLegacyPayload() throws {
        let application = try JSONDecoder().decode(RemoteFriendApplication.self, from: Data("""
        {
          "id": "application-legacy",
          "applicant_uid": "ordinary-peer",
          "target_uid": "internal-current",
          "status": "pending",
          "tenant_review_status": "approved",
          "requires_target_approval": true
        }
        """.utf8))

        let projected = try XCTUnwrap(
            AppState.friendRequestProjection(application, currentID: "internal-current")
        )
        XCTAssertEqual(projected.direction, "incoming")
        XCTAssertTrue(projected.canRespond)
    }

    func testRemoteGroupMemberMissingPresenceStaysOfflineByDefault() throws {
        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "u1",
          "nickname": "Alice",
          "role": "member"
        }
        """.utf8))

        XCTAssertEqual(member.status, "")
        XCTAssertFalse(member.online)
    }

    func testRemoteGroupMemberDecodesRemarkDisplayFieldsSeparately() throws {
        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "u-member",
          "user_id": "WXT000005",
          "nickname": "原始昵称",
          "raw_nickname": "原始昵称",
          "group_nickname": "群名片",
          "display_name": "客户王总",
          "display_name_source": "remark",
          "remark": "客户王总",
          "role": "member"
        }
        """.utf8))

        XCTAssertEqual(member.nickname, "原始昵称")
        XCTAssertEqual(member.rawNickname, "原始昵称")
        XCTAssertEqual(member.groupNickname, "群名片")
        XCTAssertEqual(member.displayName, "客户王总")
        XCTAssertEqual(member.displayNameSource, "remark")
        XCTAssertEqual(member.remark, "客户王总")
    }

    func testRemoteGroupSummaryDecodesSlimContract() throws {
        let summary = try JSONDecoder().decode(RemoteGroupSummary.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "全员公告群",
            "member_count": 503,
            "my_role": "member"
          },
          "my_role": "admin",
          "counts": {
            "member_count": "503",
            "admin_count": 6,
            "pendingJoinRequestCount": "2",
            "fileCount": 4
          },
          "member_preview": [
            {
              "im_uid": "u1",
              "nickname": "群主",
              "role": "owner",
              "is_owner": true
            }
          ],
          "settings": {
            "invite_confirm_required": true,
            "file_count": 4
          }
        }
        """.utf8))

        XCTAssertEqual(summary.summary.groupID, "g1")
        XCTAssertEqual(summary.myRole, "admin")
        XCTAssertEqual(summary.memberCount, 503)
        XCTAssertEqual(summary.counts.pendingJoinRequestCount, 2)
        XCTAssertEqual(summary.counts.fileCount, 4)
        XCTAssertEqual(summary.memberPreview.first?.imUID, "u1")
        XCTAssertFalse(summary.isMemberPreviewComplete)
        XCTAssertTrue(summary.settings.inviteConfirmRequired)
    }

    func testRemoteListDecodesMembersPaginationFields() throws {
        let list = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data("""
        {
          "items": [
            {
              "im_uid": "u1",
              "nickname": "Alice",
              "role": "member"
            }
          ],
          "self_member": {
            "im_uid": "self-1",
            "nickname": "全局昵称",
            "group_nickname": "我的群昵称",
            "role": "member",
            "revision": 9,
            "group_membership_generation": 12
          },
          "total_count": "503",
          "limit": "120",
          "offset": 20,
          "hasMore": "true",
          "nextOffset": "140"
        }
        """.utf8))

        XCTAssertEqual(list.items.map(\.imUID), ["u1"])
        XCTAssertEqual(list.selfMember?.imUID, "self-1")
        XCTAssertEqual(list.selfMember?.groupNickname, "我的群昵称")
        XCTAssertEqual(list.selfMember?.groupMembershipGeneration, 12)
        XCTAssertEqual(list.total, 503)
        XCTAssertEqual(list.limit, 120)
        XCTAssertEqual(list.offset, 20)
        XCTAssertEqual(list.hasMore, true)
        XCTAssertEqual(list.nextOffset, 140)
    }

    func testRemoteGroupDecodesInviteConfirmRequiredAliasesWithPriority() throws {
        let camelGroup = try JSONDecoder().decode(RemoteUserGroup.self, from: Data("""
        {
          "group_id": "g1",
          "name": "审批群",
          "inviteConfirmRequired": true
        }
        """.utf8))
        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "审批群"
          },
          "settings": {
            "invite_confirm_required": false,
            "inviteConfirmRequired": true,
            "approval": true
          }
        }
        """.utf8))

        XCTAssertTrue(camelGroup.inviteConfirmRequired)
        XCTAssertFalse(detail.settings.inviteConfirmRequired)
    }

    func testRemoteVerificationStatusKeepsMaskedPresentationWithoutTreatingItAsProof() throws {
        let status = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data("""
        {
          "im_uid": "WXT00000002",
          "account_id": "admin2",
          "phone_masked": "138****1001",
          "real_name_verified": false,
          "real_name_status": "unsubmitted"
        }
        """.utf8))

        XCTAssertFalse(status.phoneBound)
        XCTAssertFalse(status.phoneBindingKnown)
        XCTAssertEqual(status.phoneMasked, "138****1001")
        XCTAssertNil(status.phoneRequirementSatisfied)
        XCTAssertNil(status.realNameRequirementSatisfied)
    }

    func testBackendCreatedOrdinaryAndInternalUsersUseOnlyMatchedRequirementBooleans() throws {
        for (imUID, localID) in [
            ("ordinary-created-by-admin", "ordinary-created-by-admin"),
            ("internal-created-by-admin", "internal-local-record")
        ] {
            let status = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data("""
            {
              "im_uid": "\(imUID)",
              "phone_requirement_satisfied": true,
              "real_name_requirement_satisfied": true,
              "phone_masked": "138****1001",
              "real_name_masked": "张*",
              "real_name_status": "approved"
            }
            """.utf8))
            let user = makeForcedAuthUser(
                id: localID,
                userID: imUID,
                realNameVerified: false,
                realNameStatus: "unsubmitted",
                phoneVerified: false
            )

            let projection = verificationRequirementAuthorityProjection(
                status: status,
                currentUser: user
            )

            XCTAssertEqual(projection?.phoneSatisfied, true)
            XCTAssertEqual(projection?.realNameSatisfied, true)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteVerificationStatus.self,
                from: Data(#"{"im_uid":"ordinary-created-by-admin","phone_requirement_satisfied":"true","real_name_requirement_satisfied":true}"#.utf8)
            )
        )
    }

    func testVerificationRequirementAuthorityFailsClosedForFalseMissingAndCrossUserPayloads() throws {
        let user = makeForcedAuthUser(
            id: "uid-current",
            realNameVerified: true,
            realNameStatus: "approved",
            phoneVerified: true
        )
        let explicitFalse = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-current","phone_requirement_satisfied":false,"real_name_requirement_satisfied":false}"#.utf8))
        let missing = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-current","phone_masked":"138****1001","real_name_status":"approved"}"#.utf8))
        let crossUser = try JSONDecoder().decode(RemoteVerificationStatus.self, from: Data(#"{"im_uid":"uid-other","phone_requirement_satisfied":true,"real_name_requirement_satisfied":true}"#.utf8))

        XCTAssertEqual(
            verificationRequirementAuthorityProjection(status: explicitFalse, currentUser: user),
            VerificationRequirementAuthorityProjection(phoneSatisfied: false, realNameSatisfied: false)
        )
        XCTAssertEqual(
            verificationRequirementAuthorityProjection(status: missing, currentUser: user),
            VerificationRequirementAuthorityProjection(phoneSatisfied: false, realNameSatisfied: false)
        )
        XCTAssertNil(verificationRequirementAuthorityProjection(status: crossUser, currentUser: user))
    }

    func testRemoteIMUserDecodesMaskedPhoneAsVerifiedSnapshot() throws {
        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "WXT00000002",
          "user_id": "WXT00000002",
          "account_id": "admin2",
          "nickname": "admin2",
          "phone_masked": "138****1001"
        }
        """.utf8))

        XCTAssertEqual(user.phone, "138****1001")
        XCTAssertTrue(user.phoneVerified)
    }

    func testRemoteAuthDataDecodesTenantMemberDefaultAvatar() throws {
        let data = try JSONDecoder().decode(RemoteAuthData.self, from: Data("""
        {
          "account": {
            "id": "acct-1",
            "username": "admin13",
            "phone": "",
            "status": "normal"
          },
          "platform_token": "platform-token",
          "tenant": {
            "id": "tenant-1",
            "tenant_code": "WXT000001",
            "name": "Default Enterprise",
            "status": "enabled"
          },
          "tenant_member": {
            "id": "tm-1",
            "tenant_id": "tenant-1",
            "account_id": "acct-1",
            "im_uid": "WXT56697668",
            "nickname": "admin13",
            "avatar": "/api/tenant/static/avatars/default-users/user-default-avatar-07.png",
            "avatar_version": "default-user-avatar-07",
            "avatar_updated_at": "2026-06-27T00:00:00Z",
            "status": "normal",
            "role": "member"
          }
        }
        """.utf8))

        let member = try XCTUnwrap(data.tenantMember)
        XCTAssertEqual(member.avatar, "/api/tenant/static/avatars/default-users/user-default-avatar-07.png")
        XCTAssertEqual(member.avatarVersion, "default-user-avatar-07")
        XCTAssertEqual(member.avatarUpdatedAt, "2026-06-27T00:00:00Z")
    }

    func testRemoteGroupMemberProfileDecodesFrozenContractAndGenerationFallback() throws {
        let profile = try JSONDecoder().decode(
            RemoteGroupMemberProfile.self,
            from: Data(
                #"""
                {
                  "contract_version": 1,
                  "group_id": "group-a",
                  "im_uid": "uid-1",
                  "group_nickname": "A 群昵称",
                  "raw_nickname": "全局昵称",
                  "display_name": "A 群昵称",
                  "display_name_source": "group_nickname",
                  "revision": 9,
                  "group_membership_generation": 12,
                  "updated_at": "2026-07-28T12:00:00Z"
                }
                """#.utf8
            )
        )

        XCTAssertEqual(profile.contractVersion, 1)
        XCTAssertEqual(profile.groupID, "group-a")
        XCTAssertEqual(profile.groupNickname, "A 群昵称")
        XCTAssertEqual(profile.rawNickname, "全局昵称")
        XCTAssertEqual(profile.displayNameSource, "group_nickname")
        XCTAssertEqual(profile.revision, 9)
        XCTAssertEqual(profile.groupMembershipGeneration, 12)
    }

    func testGroupMemberDisplayNameUsesGroupThenRemarkThenGlobalAndSelfSkipsRemark() {
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "",
                viewerRemarks: ["好友备注"],
                groupNickname: "群昵称",
                globalNickname: "全局昵称",
                stableIdentifier: "uid-1",
                isCurrentUser: false
            ),
            "群昵称"
        )
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "",
                viewerRemarks: ["不应显示的自我备注"],
                groupNickname: "我的群昵称",
                globalNickname: "我的全局昵称",
                stableIdentifier: "uid-me",
                isCurrentUser: true
            ),
            "我的群昵称"
        )
        XCTAssertEqual(
            GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "服务端展示名",
                viewerRemarks: ["本地旧备注"],
                groupNickname: "本地旧群昵称",
                globalNickname: "全局昵称",
                stableIdentifier: "uid-2",
                isCurrentUser: false
            ),
            "本地旧群昵称"
        )
    }

    func testGroupMemberDisplayNameSkipsBlankFieldsAndKeepsViewerRemarksIsolated() {
        for groupName in ["A 群昵称", "", " \n "] {
            for remark in ["查看者甲备注", "", " \t "] {
                for globalName in ["个人昵称", "", " \n "] {
                    let expected = [groupName, remark, globalName, "uid-peer"]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }!
                    XCTAssertEqual(GroupMemberDisplayNameResolver.resolve(
                        authoritativeDisplayName: "", viewerRemarks: [remark], groupNickname: groupName,
                        globalNickname: globalName, stableIdentifier: "uid-peer", isCurrentUser: false), expected)
                }
            }
        }
        for viewerRemark in ["查看者甲备注", "查看者乙备注"] {
            XCTAssertEqual(GroupMemberDisplayNameResolver.resolve(
                authoritativeDisplayName: "旧服务端展示名", viewerRemarks: [viewerRemark], groupNickname: " ",
                globalNickname: "个人昵称", stableIdentifier: "uid-peer", isCurrentUser: false), viewerRemark)
        }
    }

	func testMessageEditAuthorityDecodesRevisionVersionAndCurrentMessage() throws {
		let response = try JSONDecoder().decode(RemoteExtraResponse.self, from: Data("""
		{
		  "extra": {
		    "tenant_id": "tenant-1", "message_id": "message-1", "channel_id": "u1:u2", "channel_type": "direct",
		    "channel_seq": 4, "version": 1700000000000001024, "operator_uid": "u1", "extra_type": "edit",
		    "payload": {"client_edit_id":"edit-1","edit_revision":2,"payload":{"text":"revision two","edit_revision":2}}
		  },
		  "message": {
		    "message_id":"message-1","channel_id":"u1:u2","channel_type":"direct","channel_seq":4,"from_uid":"u1",
		    "content_type":"text","status":"edited","payload":{"text":"revision two","edit_revision":2}
		  },
		  "duplicate": false
		}
		""".utf8))
		XCTAssertEqual(response.extra?.version, 1_700_000_000_000_001_024)
		XCTAssertEqual(response.extra?.editRevision, 2)
		XCTAssertEqual(response.extra?.dedupeKey.contains("1700000000000001024"), true)
		XCTAssertEqual(response.message?.editRevision, 2)
		XCTAssertEqual(response.message?.payload["text"]?.stringValue, "revision two")
		XCTAssertFalse(response.duplicate)
	}
}
