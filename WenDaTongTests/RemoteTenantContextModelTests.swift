import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteMeProfileDecodesTenantLocalAuthorityWatermark() throws {
        let profile = try JSONDecoder().decode(RemoteMeProfile.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "user_id": "user-1",
          "username": "alice01",
          "nickname": "Alice",
          "avatar": "avatar.png",
          "user_revision": "12",
          "identity_generation": 34
        }
        """.utf8))

        XCTAssertEqual(profile.tenantID, "tenant-1")
        XCTAssertEqual(profile.imUID, "uid-1")
        XCTAssertEqual(profile.nickname, "Alice")
        XCTAssertEqual(profile.userRevision, 12)
        XCTAssertEqual(profile.identityGeneration, 34)
    }

    func testTenantContextUserDecodesSameProfileAuthorityWatermark() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "app_id": "jianhuitong-ios",
          "device_id": "device-1",
          "tenant": {"tenant_id":"tenant-1","tenant_code":"WXT000001","name":"测试企业","status":"active"},
          "user": {
            "tenant_id": "tenant-1",
            "im_uid": "uid-1",
            "user_id": "user-1",
            "username": "alice01",
            "nickname": "Alice",
            "avatar": "avatar.png",
            "user_revision": 12,
            "identity_generation": "34"
          }
        }
        """.utf8))

        let user = try XCTUnwrap(context.user)
        XCTAssertEqual(user.tenantID, "tenant-1")
        XCTAssertEqual(user.imUID, "uid-1")
        XCTAssertEqual(user.nickname, "Alice")
        XCTAssertEqual(user.userRevision, 12)
        XCTAssertEqual(user.identityGeneration, 34)
    }

    func testRemoteTenantContextDecodesGlobalPolicyNestedAndDefaults() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "im-1",
          "app_id": "jianhuitong-ios",
          "device_id": "ios-1",
          "tenant_policy": {
            "group": {
              "allow_member_group_creation": true,
              "hide_membership_system_messages": true
            },
            "relationship": {
              "client_friend_requests": true
            },
            "visibility": {
              "show_online_status": false,
              "show_last_login_time": true
            },
            "device": {
              "login_require_bound_device": true
            },
            "export": {
              "message_export_enabled": true
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertTrue(policy.allowMemberGroupCreation)
        XCTAssertTrue(policy.hideMembershipSystemMessages)
        XCTAssertTrue(policy.clientFriendRequests)
        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertFalse(policy.showOnlineStatus)
        XCTAssertTrue(policy.showLastLoginTime)
        XCTAssertTrue(policy.loginRequireBoundDevice)
        XCTAssertTrue(policy.messageExportEnabled)
    }

    func testRemoteTenantContextDecodesAuthoritativeMultiDevicePolicy() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "uid-1",
          "app_id": "jianhuitong-ios",
          "device_id": "device-1",
          "tenant": {"id":"tenant-1","tenantName":"Tenant"},
          "tenant_policy": {
            "device": {
              "multi_device_enabled": true,
              "authoritative": true,
              "contract_version": 1
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertTrue(policy.multiDevicePolicyPresent)
        XCTAssertTrue(policy.multiDevicePolicyAuthoritative)
        XCTAssertEqual(policy.multiDeviceContractVersion, 1)
        XCTAssertTrue(policy.multiDeviceEnabled)
    }

    func testRemoteTenantContextTreatsIncompleteOrMalformedMultiDevicePolicyAsUnresolved() throws {
        let malformedDevicePolicies = [
            #"{"multi_device_enabled":true,"contract_version":1}"#,
            #"{"multi_device_enabled":"true","authoritative":true,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":"true","contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":true,"contract_version":"1"}"#,
            #"{"multi_device_enabled":true,"authoritative":false,"contract_version":1}"#,
            #"{"multi_device_enabled":true,"authoritative":true,"contract_version":2}"#
        ]

        for devicePolicy in malformedDevicePolicies {
            let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
            {"device":\(devicePolicy)}
            """.utf8))
            XCTAssertFalse(policy.multiDevicePolicyPresent, "must not claim authority for \(devicePolicy)")
        }
    }

    func testRemoteTenantContextDecodesRestrictiveGroupMemberCountWatermark() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "tenant_policy": {
            "visibility": {
              "show_group_member_count": false,
              "tenant_policy_generation": 12,
              "contract_version": 1,
              "authoritative": false
            }
          }
        }
        """.utf8))

        let policy = try XCTUnwrap(context.clientPolicy)
        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 12)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 1)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertTrue(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyAcceptsFutureCompatibleGroupMemberCountContractVersion() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "tenant_policy_generation": 13,
            "contract_version": 2,
            "authoritative": true
          }
        }
        """.utf8))

        XCTAssertTrue(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 13)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 2)
        XCTAssertTrue(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertTrue(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyMissingGroupMemberCountFieldsUsesHiddenUnresolvedDefaults() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data(#"{}"#.utf8))

        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyRejectsMalformedCanonicalGroupMemberCountTypes() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": "true",
            "tenant_policy_generation": "12",
            "contract_version": 1.5,
            "authoritative": 1
          }
        }
        """.utf8))

        XCTAssertFalse(policy.showGroupMemberCount)
        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyPartialGroupMemberCountContractRemainsUnresolved() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "tenant_policy_generation": 3,
            "contract_version": 1
          }
        }
        """.utf8))

        XCTAssertTrue(policy.showGroupMemberCount)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantPolicyRejectsDeprecatedCandidateWatermarkKeys() throws {
        let policy = try JSONDecoder().decode(RemoteTenantClientPolicy.self, from: Data("""
        {
          "visibility": {
            "show_group_member_count": true,
            "group_member_count_policy_generation": 99,
            "group_member_count_contract_version": 1,
            "group_member_count_policy_authoritative": true
          }
        }
        """.utf8))

        XCTAssertEqual(policy.groupMemberCountPolicyGeneration, 0)
        XCTAssertEqual(policy.groupMemberCountContractVersion, 0)
        XCTAssertFalse(policy.groupMemberCountPolicyAuthoritative)
        XCTAssertFalse(policy.groupMemberCountPolicyPresent)
    }

    func testRemoteTenantContextDecodesOnlyInternalCompatAsInverse() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "tenantPolicy": {
            "group": {
              "onlyInternalCanCreateGroup": false
            }
          }
        }
        """.utf8))

        XCTAssertEqual(context.clientPolicy?.allowMemberGroupCreation, true)
    }

    func testRemotePresenceAndLastLoginFieldsDecodeWithoutInferringOffline() throws {
        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "im-1",
          "user_id": "u-1",
          "nickname": "Alice",
          "status": "hidden",
          "last_seen_at": "2026-07-23T01:02:03Z"
        }
        """.utf8))
        XCTAssertEqual(user.status, "hidden")
        XCTAssertEqual(user.lastSeenAt, "2026-07-23T01:02:03Z")

        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "owner_uid": "me",
          "friend_uid": "friend-1",
          "friend_nickname": "Bob",
          "friend_status": "unknown",
          "friend_last_seen_at": "今天 08:52"
        }
        """.utf8))
        XCTAssertEqual(relation.friendStatus, "unknown")
        XCTAssertFalse(relation.friendOnlineKnown)
        XCTAssertEqual(relation.friendLastSeenAt, "今天 08:52")
    }

    func testTenantLoginWorkspaceKeepsEnterableWhenSwitchDisabled() throws {
        let login = try JSONDecoder().decode(RemoteTenantLoginData.self, from: Data("""
        {
          "platform_token": "platform-token",
          "can_direct_enter": true,
          "requires_workspace_selection": false,
          "auto_entered_workspace_id": "tenant-1",
          "workspaces": [
            {
              "id": "tenant-1",
              "name": "Local Tenant",
              "tenant_code": "WXT000001",
              "status": "active",
              "member_status": "active",
              "enterable": true,
              "can_switch": false
            }
          ]
        }
        """.utf8))

        let workspace = try XCTUnwrap(login.workspaces.first)
        XCTAssertTrue(login.canDirectEnter)
        XCTAssertFalse(login.requiresWorkspaceSelection)
        XCTAssertEqual(login.autoEnteredWorkspaceID, "tenant-1")
        XCTAssertEqual(workspace.enterable, true)
        XCTAssertFalse(workspace.canSwitch)
    }

    func testTenantSearchResponseDecodesBucketsHighlightsAndJumpTarget() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "search_id": "search-1",
          "request_id": "req-1",
          "elapsed_ms": 8,
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:msg-1",
                  "type": "message",
                  "title": "张三",
                  "subtitle": "昨天 19:03",
                  "snippet": "这里有合同正文",
                  "highlight_ranges": [
                    {"field":"snippet","start":3,"length":2}
                  ],
                  "rank": 9.5,
                  "jump_target": {
                    "kind": "message",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 42,
                    "message_id": "msg-1"
                  },
                  "source": {"visibility":"remote"}
                }
              ],
              "count": 1,
              "has_more": false
            },
            "files": {
              "items": [
                {
                  "result_id": "file:file-1",
                  "type": "file",
                  "title": "合同.pdf",
                  "source": "tenant.files",
                  "highlight_ranges": [
                    {"field":"title","start":0,"length":2}
                  ],
                  "jumpTarget": {
                    "kind": "message_file",
                    "channelId": "group-1",
                    "channelType": "group",
                    "channelSeq": "43",
                    "messageId": "msg-2",
                    "fileId": "file-1"
                  }
                }
              ],
              "count": 1,
              "hasMore": true,
              "nextCursor": "cursor-file"
            }
          },
          "items": [],
          "compatibility": {},
          "analytics": {},
          "parsed_filters": [
            {"type":"sender","key":"from","operator":"from","value":"u_100","label":"来自 u_100","raw":"from:u_100"},
            {"type":"date","key":"before","operator":"before","value":"2026-06-27"}
          ],
          "conversation_search": {
            "hit_channel_seqs": [42, 43],
            "total": 2,
            "next_cursor": "cursor-next"
          },
          "conversation_date_anchor": {
            "date": "2026-06-27",
            "status": "nearest",
            "nearest_channel_seq": 43,
            "nearest_message_id": "msg-2",
            "direction": "after"
          }
        }
        """.utf8))

        XCTAssertEqual(response.query, "合同")
        XCTAssertEqual(response.scope, "conversation")
        XCTAssertEqual(response.searchID, "search-1")
        XCTAssertEqual(response.elapsedMS, 8)
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.id, "message:message:msg-1")
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.highlightRanges.first, RemoteTenantSearchHighlightRange(field: "snippet", start: 3, length: 2))
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.jumpTarget?.channelSeq, 42)
        XCTAssertEqual(response.resultsByType["messages"]?.items.first?.source["visibility"]?.stringValue, "remote")
        XCTAssertEqual(response.resultsByType["files"]?.hasMore, true)
        XCTAssertEqual(response.resultsByType["files"]?.nextCursor, "cursor-file")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.jumpTarget?.fileID, "file-1")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.sourceName, "tenant.files")
        XCTAssertEqual(response.resultsByType["files"]?.items.first?.source["name"]?.stringValue, "tenant.files")
        XCTAssertEqual(response.parsedFilters.map(\.displayTitle), ["来自 u_100", "before: 2026-06-27"])
        XCTAssertEqual(response.conversationSearch?.hitChannelSeqs, [42, 43])
        XCTAssertEqual(response.conversationSearch?.nextCursor, "cursor-next")
        XCTAssertEqual(response.conversationDateAnchor?.nearestChannelSeq, 43)
        XCTAssertEqual(response.conversationDateAnchor?.bestJumpTarget?.messageID, "msg-2")
    }
}
