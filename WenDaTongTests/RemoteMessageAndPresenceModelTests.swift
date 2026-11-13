import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteMessageDecodesAliasesAndPayloadFallbacks() throws {
        let json = """
        {
          "id": "msg-1",
          "client_id": "client-1",
            "payload": {
              "channel_id": "direct-u1-u2",
              "channel_type": "direct",
              "from_uid": "u1",
              "sender_name": "Alice",
              "sender_avatar_url": "https://example.test/a.png",
              "sender_avatar_version": "v7",
              "sender_avatar_updated_at": "2026-06-26T01:00:00Z",
              "content_type": "text",
              "client_msg_no": "payload-client"
            },
          "seq": 42,
          "quoted_text": "previous",
          "status": "sent",
          "read_status": "read",
          "read_count": 3,
          "read_at": "2026-06-23T01:02:03Z",
          "created_at": "2026-06-23T01:00:00Z"
        }
        """

        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.messageID, "msg-1")
        XCTAssertEqual(message.clientMsgNo, "client-1")
        XCTAssertEqual(message.channelID, "direct-u1-u2")
        XCTAssertEqual(message.channelType, "direct")
        XCTAssertEqual(message.channelSeq, 42)
        XCTAssertEqual(message.fromUID, "u1")
        XCTAssertEqual(message.senderProvenance, .clientSupplied)
        XCTAssertEqual(message.senderDisplayName, "Alice")
        XCTAssertEqual(message.senderAvatar, "https://example.test/a.png")
        XCTAssertEqual(message.senderAvatarVersion, "v7")
        XCTAssertEqual(message.senderAvatarUpdatedAt, "2026-06-26T01:00:00Z")
        XCTAssertEqual(message.contentType, "text")
        XCTAssertEqual(message.quote, "previous")
        XCTAssertEqual(message.readCount, 3)
    }

    func testRemoteMessageSenderProvenanceRequiresStoredTopLevelSender() throws {
        let authoritative = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "stored-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 7,
          "sender_uid": "actor-1",
          "content_type": "voice",
          "payload": {"sender_uid": "spoofed-actor"},
          "created_at": "2026-07-28T01:00:00Z"
        }
        """.utf8))
        let payloadOnly = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "payload-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 8,
          "content_type": "voice",
          "payload": {"sender_uid": "actor-1"},
          "created_at": "2026-07-28T01:00:01Z"
        }
        """.utf8))
        let missing = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "missing-sender",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 9,
          "content_type": "voice",
          "payload": {},
          "created_at": "2026-07-28T01:00:02Z"
        }
        """.utf8))

        XCTAssertEqual(authoritative.fromUID, "actor-1")
        XCTAssertEqual(authoritative.senderProvenance, .authoritativeStored)
        XCTAssertEqual(payloadOnly.fromUID, "actor-1")
        XCTAssertEqual(payloadOnly.senderProvenance, .clientSupplied)
        XCTAssertEqual(missing.fromUID, "")
        XCTAssertEqual(missing.senderProvenance, .unknown)
    }

    func testRemoteMessageDecodesEditedStatusAndAliases() throws {
        let statusEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 8,
          "from_uid": "u1",
          "content_type": "text",
          "payload": {"text": "updated text"},
          "status": "edited",
          "created_at": "2026-06-23T01:00:00Z"
        }
        """.utf8))
        let payloadEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-2",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 9,
          "from_uid": "u2",
          "content_type": "text",
          "payload": {"text": "new text", "edited_at": "2026-06-23T01:01:00Z"},
          "status": "sent"
        }
        """.utf8))
        let boolEdited = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-edited-3",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 10,
          "from_uid": "u3",
          "content_type": "text",
          "payload": {"text": "new text"},
          "is_edited": true,
          "status": "sent"
        }
        """.utf8))

        XCTAssertTrue(statusEdited.isEdited)
        XCTAssertTrue(payloadEdited.isEdited)
        XCTAssertTrue(boolEdited.isEdited)
    }

    func testRemoteAttachmentNameDoesNotBecomeSenderDisplayName() throws {
        let json = """
        {
          "message_id": "msg-file-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 43,
          "from_uid": "u2",
          "content_type": "file",
          "payload": {
            "file_id": "file-1",
            "file_name": "frontend-slides-main.zip",
            "name": "frontend-slides-main.zip",
            "media_category": "archive"
          },
          "status": "sent",
          "created_at": "2026-06-23T01:01:00Z"
        }
        """

        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.senderDisplayName, "")
        XCTAssertEqual(message.payload["name"]?.stringValue, "frontend-slides-main.zip")
    }

    func testRemoteConversationDecodesDisplayAndUnreadFallbacks() throws {
        let json = """
        {
          "channel_id": "group-1",
          "channel_type": "group",
          "unread_count": 5,
          "unread_reaction_count": 2,
          "has_reaction_unread": "true",
          "last_msg_seq": 100,
          "last_read": 80,
          "first_unread_seq": 81,
          "version": 7,
          "pinned": true,
          "mute": true,
          "displayName": "Design Group",
          "last_message": {
            "message_id": "msg-2",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 100,
            "from_uid": "u2",
            "sender_display_name": "Bob",
            "content_type": "text",
            "payload": {"text": "hello"},
            "status": "sent"
          },
          "pinned_messages": [],
          "has_mention": true,
          "mention_count": 1,
          "mention_summary": {
            "type": "mention",
            "text": "@you",
            "message_id": "msg-2",
            "channel_seq": 100
          }
        }
        """

        let conversation = try JSONDecoder().decode(RemoteConversation.self, from: Data(json.utf8))

        XCTAssertEqual(conversation.channelID, "group-1")
        XCTAssertEqual(conversation.displayName, "Design Group")
        XCTAssertEqual(conversation.lastReadSeq, 80)
        XCTAssertEqual(conversation.unreadAnchorSeq, 81)
        XCTAssertEqual(conversation.unreadAnchorState, "ready")
        XCTAssertTrue(conversation.stick)
        XCTAssertTrue(conversation.mute)
        XCTAssertTrue(conversation.hasReactionUnread)
        XCTAssertEqual(conversation.lastMessage?.messageID, "msg-2")
        XCTAssertTrue(conversation.pinnedMessagesProvided)
        XCTAssertEqual(conversation.mentionSummary?.messageID, "msg-2")
    }

    func testRemoteConversationSyncDecodesMultiplePinnedAliases() throws {
        let json = """
        {
          "version": 9,
          "conversations": [
            {
              "channel_id": "stick-only",
              "channel_type": "group",
              "pinned": false,
              "stick": true,
              "mute": false,
              "muted": true,
              "display_name": "Stick Only"
            },
            {
              "channel_id": "is-pinned",
              "channel_type": "group",
              "is_pinned": true,
              "dnd": "true",
              "display_name": "Is Pinned"
            },
            {
              "channel_id": "sticky",
              "channel_type": "group",
              "sticky": 1,
              "is_muted": 1,
              "display_name": "Sticky"
            },
            {
              "channel_id": "top",
              "channel_type": "group",
              "top": "true",
              "doNotDisturb": true,
              "display_name": "Top"
            },
            {
              "channel_id": "regular",
              "channel_type": "group",
              "pinned": false,
              "stick": false,
              "mute": false,
              "muted": false,
              "dnd": false,
              "display_name": "Regular"
            }
          ]
        }
        """

        let sync = try JSONDecoder().decode(RemoteConversationSyncData.self, from: Data(json.utf8))

        XCTAssertEqual(
            sync.conversations.filter(\.stick).map(\.channelID),
            ["stick-only", "is-pinned", "sticky", "top"]
        )
        XCTAssertEqual(
            sync.conversations.filter(\.mute).map(\.channelID),
            ["stick-only", "is-pinned", "sticky", "top"]
        )
        XCTAssertFalse(sync.conversations.first { $0.channelID == "regular" }?.stick ?? true)
        XCTAssertFalse(sync.conversations.first { $0.channelID == "regular" }?.mute ?? true)
    }

    func testRemoteGroupDecodesMemberCountAliases() throws {
        let group = try JSONDecoder().decode(RemoteUserGroup.self, from: Data("""
        {
          "group_id": "g1",
          "name": "交易通知群",
          "totalMembers": "91",
          "my_role": "member"
        }
        """.utf8))
        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "交易通知群",
            "membersTotal": 80,
            "my_role": "member"
          },
          "member_num": "91"
        }
        """.utf8))
        let list = try JSONDecoder().decode(RemoteList<RemoteUserGroupMember>.self, from: Data("""
        {
          "items": [],
          "total_count": "91"
        }
        """.utf8))

        XCTAssertEqual(group.memberCount, 91)
        XCTAssertEqual(detail.memberCount, 91)
        XCTAssertEqual(list.total, 91)
    }

    func testRemoteFriendRelationDecodesPresenceWithoutDefaultingOnline() throws {
        let offline = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-offline",
          "friend_user_id": "WXT000001",
          "friend_nickname": "离线用户"
        }
        """.utf8))
        XCTAssertEqual(offline.friendStatus, "")
        XCTAssertFalse(offline.friendOnline)

        let online = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "u-online",
          "friend_user_id": "WXT000002",
          "friend_nickname": "在线用户",
          "friend_status": "online",
          "is_online": "true"
        }
        """.utf8))
        XCTAssertEqual(online.friendStatus, "online")
        XCTAssertTrue(online.friendOnline)
    }

    func testRemoteFriendRelationKeepsAuthoritativeFriendUIDSeparateFromCompatibilityFallbacks() throws {
        let canonical = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "im-canonical-1",
          "friend_user_id": "WXT000001",
          "peer_uid": "legacy-peer"
        }
        """.utf8))
        XCTAssertEqual(canonical.friendUID, "im-canonical-1")
        XCTAssertEqual(canonical.authoritativeFriendUID, "im-canonical-1")
        XCTAssertEqual(canonical.authoritativeFriendUserID, "WXT000001")

        let compatibilityOnly = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_user_id": "WXT000002",
          "peer_uid": "legacy-peer"
        }
        """.utf8))
        XCTAssertEqual(compatibilityOnly.friendUID, "WXT000002")
        XCTAssertNil(compatibilityOnly.authoritativeFriendUID)
        XCTAssertEqual(compatibilityOnly.authoritativeFriendUserID, "WXT000002")
    }

    func testPresenceStatusDecodingKeepsExplicitAuthoritySeparateFromCompatibilityFields() throws {
        let relation = try JSONDecoder().decode(RemoteFriendRelation.self, from: Data("""
        {
          "friend_uid": "friend-1",
          "presence_status": "offline",
          "friend_status": "online",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(relation.friendStatus, "offline")
        XCTAssertTrue(relation.friendOnline)
        XCTAssertTrue(relation.friendOnlineKnown)

        let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "member-1",
          "status": "cancelled",
          "presence_status": "online",
          "online": false
        }
        """.utf8))
        XCTAssertEqual(member.status, "cancelled")
        XCTAssertEqual(member.presenceStatus, "online")
        XCTAssertFalse(member.online)
        XCTAssertTrue(member.onlineKnown)

        let user = try JSONDecoder().decode(RemoteIMUser.self, from: Data("""
        {
          "im_uid": "user-1",
          "status": "enabled",
          "presence_status": "away",
          "is_online": false
        }
        """.utf8))
        XCTAssertEqual(user.status, "enabled")
        XCTAssertEqual(user.presenceStatus, "away")
        XCTAssertFalse(user.online)
        XCTAssertTrue(user.onlineKnown)

        let me = try JSONDecoder().decode(RemoteMeProfile.self, from: Data("""
        {
          "im_uid": "viewer-1",
          "status": "enabled",
          "presence_status": "busy",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(me.status, "enabled")
        XCTAssertEqual(me.presenceStatus, "busy")
        XCTAssertTrue(me.online)

        let organizationMember = try JSONDecoder().decode(RemoteOrganizationMemberView.self, from: Data("""
        {
          "im_uid": "organization-1",
          "status": "enabled",
          "presence_status": "dnd",
          "isOnline": true
        }
        """.utf8))
        XCTAssertEqual(organizationMember.status, "enabled")
        XCTAssertEqual(organizationMember.presenceStatus, "dnd")
        XCTAssertTrue(organizationMember.online)

        let searchItem = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "search-1",
          "status": "cancelled",
          "presence_status": "hidden",
          "online": true
        }
        """.utf8))
        XCTAssertEqual(searchItem.status, "cancelled")
        XCTAssertEqual(searchItem.presenceStatus, "hidden")
        XCTAssertTrue(searchItem.online)

        let searchItemWithoutPresence = try JSONDecoder().decode(RemoteUserSearchItem.self, from: Data("""
        {
          "im_uid": "search-2",
          "status": "cancelled",
          "online": false
        }
        """.utf8))
        XCTAssertEqual(searchItemWithoutPresence.status, "cancelled")
        XCTAssertEqual(searchItemWithoutPresence.presenceStatus, "")
        XCTAssertFalse(searchItemWithoutPresence.online)
        XCTAssertTrue(searchItemWithoutPresence.onlineKnown)

        let memberWithoutPresence = try JSONDecoder().decode(RemoteUserGroupMember.self, from: Data("""
        {
          "im_uid": "member-2",
          "status": "cancelled",
          "is_online": true
        }
        """.utf8))
        XCTAssertEqual(memberWithoutPresence.status, "cancelled")
        XCTAssertEqual(memberWithoutPresence.presenceStatus, "")
        XCTAssertTrue(memberWithoutPresence.online)
        XCTAssertTrue(memberWithoutPresence.onlineKnown)
    }

	func testMessageEditExtraRequiresExplicitAuthoritativeEditRevision() throws {
		let extra = try JSONDecoder().decode(RemoteMessageExtra.self, from: Data("""
		{
		  "tenant_id":"tenant-1", "message_id":"message-legacy", "channel_id":"u1:u2", "channel_type":"direct",
		  "channel_seq":5, "version":1700000000000002048, "operator_uid":"u1", "extra_type":"edit",
		  "payload":{"payload":{"text":"legacy edit without revision"}}
		}
		""".utf8))
		XCTAssertEqual(extra.version, 1_700_000_000_000_002_048)
		XCTAssertEqual(extra.editRevision, 0)
	}
}
