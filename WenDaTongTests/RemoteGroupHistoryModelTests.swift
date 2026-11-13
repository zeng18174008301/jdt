import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteMessageSyncResultDecodesHistoryBoundaryEnvelope() throws {
        let result = try JSONDecoder().decode(RemoteMessageSyncResult.self, from: Data("""
        {
          "items": [
            {
              "message_id": "m421",
              "channel_id": "g1",
              "channel_type": "group",
              "channel_seq": 421,
              "from_uid": "u1",
              "content_type": "text",
              "payload": {},
              "status": "normal"
            }
          ],
          "has_more_before": false,
          "has_more_after": true,
          "next_after_seq": "421",
          "history_visible_from_seq": "421",
          "history_limited": true
        }
        """.utf8))

        XCTAssertEqual(result.items.map(\.messageID), ["m421"])
        XCTAssertEqual(result.hasMoreBefore, false)
        XCTAssertEqual(result.hasMoreAfter, true)
        XCTAssertEqual(result.nextAfterSeq, 421)
        XCTAssertEqual(result.historyVisibleFromSeq, 421)
        XCTAssertTrue(result.historyLimited)
    }

    func testGroupHistoryVisibilityContractDecodesSummarySettingsAndConversationFields() throws {
        let legacySettings = try JSONDecoder().decode(RemoteGroupSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertTrue(legacySettings.historyVisible)

        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "summary": {
            "group_id": "g1",
            "name": "Group",
            "history_visible_from_seq": 421,
            "history_limited": true
          },
          "settings": {
            "history_visible": false
          },
          "my_role": "admin"
        }
        """.utf8))
        XCTAssertEqual(detail.historyVisibleFromSeq, 421)
        XCTAssertTrue(detail.historyLimited)
        XCTAssertFalse(detail.settings.historyVisible)

        let conversation = try JSONDecoder().decode(RemoteConversation.self, from: Data("""
        {
          "channel_id": "g1",
          "channel_type": "group",
          "last_msg_seq": 430,
          "history_visible_from_seq": 421,
          "history_limited": true
        }
        """.utf8))
        XCTAssertEqual(conversation.historyVisibleFromSeq, 421)
        XCTAssertTrue(conversation.historyLimited)
    }

    func testGroupMuteListContractDecodesSummaryDetailSettingsAndItems() throws {
        let legacySettings = try JSONDecoder().decode(RemoteGroupSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertNil(legacySettings.canManageMuteList)
        XCTAssertNil(legacySettings.muteListCount)

        let summary = try JSONDecoder().decode(RemoteGroupSummary.self, from: Data("""
        {
          "group": {
            "group_id": "g1",
            "name": "Mute Group",
            "group_muted": true,
            "can_manage_mute_list": false,
            "mute_list_count": "2"
          },
          "settings": {
            "can_manage_mute_list": true,
            "mute_list_count": 3
          },
          "group_muted": false,
          "can_manage_mute_list": true,
          "mute_list_count": 3
        }
        """.utf8))
        XCTAssertFalse(summary.groupMuted)
        XCTAssertTrue(summary.canManageMuteList == true)
        XCTAssertEqual(summary.muteListCount, 3)

        let detail = try JSONDecoder().decode(RemoteGroupDetail.self, from: Data("""
        {
          "summary": {
            "group_id": "g1",
            "name": "Mute Group",
            "group_muted": true,
            "can_manage_mute_list": false,
            "mute_list_count": 2
          },
          "settings": {
            "history_visible": true
          },
          "my_role": "admin"
        }
        """.utf8))
        XCTAssertTrue(detail.groupMuted)
        XCTAssertFalse(detail.canManageMuteList == true)
        XCTAssertEqual(detail.muteListCount, 2)

        let list = try JSONDecoder().decode(RemoteList<RemoteGroupMuteListItem>.self, from: Data("""
        {
          "items": [
            {
              "group_id": "g1",
              "target_uid": "uid-target",
              "target_user_id": "WXTAB123456",
              "target_username": "username07",
              "target_nickname": "王同学",
              "target_avatar": "/avatars/a.png",
              "target_role": "member",
              "operator_uid": "uid-admin",
              "operator_name": "管理员",
              "reason": "广告刷屏",
              "created_at": "2026-07-22T10:00:00Z",
              "updated_at": "2026-07-22T10:05:00Z"
            }
          ]
        }
        """.utf8))
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.groupID, "g1")
        XCTAssertEqual(item.targetUID, "uid-target")
        XCTAssertEqual(item.targetUserID, "WXTAB123456")
        XCTAssertEqual(item.targetUsername, "username07")
        XCTAssertEqual(item.targetNickname, "王同学")
        XCTAssertEqual(item.targetAvatar, "/avatars/a.png")
        XCTAssertEqual(item.targetRole, "member")
        XCTAssertEqual(item.operatorUID, "uid-admin")
        XCTAssertEqual(item.operatorName, "管理员")
        XCTAssertEqual(item.reason, "广告刷屏")
    }

    func testRemoteGroupFileDecodesChannelSeqForHistoryBoundaryFiltering() throws {
        let file = try JSONDecoder().decode(RemoteGroupFile.self, from: Data("""
        {
          "file_id": "file-421",
          "name": "visible.pdf",
          "mime_type": "application/pdf",
          "size_bytes": 2048,
          "channel_id": "g1",
          "channel_type": "group",
          "channel_seq": "421"
        }
        """.utf8))

        XCTAssertEqual(file.fileID, "file-421")
        XCTAssertEqual(file.channelID, "g1")
        XCTAssertEqual(file.channelSeq, 421)
    }

    func testRemoteGroupFilePreservesVoiceClassificationFieldsForFileListFiltering() throws {
        let file = try JSONDecoder().decode(RemoteGroupFile.self, from: Data("""
        {
          "file_id": "voice-file-1",
          "name": "voice-legacy.webm",
          "mime_type": "audio/webm",
          "size_bytes": 2048,
          "channel_id": "g1",
          "channel_type": "group",
          "content_type": "file",
          "media_category": "voice",
          "kind": "voice"
        }
        """.utf8))

        XCTAssertEqual(file.contentType, "file")
        XCTAssertEqual(file.mediaCategory, "voice")
        XCTAssertEqual(file.kind, "voice")
    }

    func testRemoteUserFilePreservesVoiceClassificationFieldsForFileListFiltering() throws {
        let file = try JSONDecoder().decode(RemoteUserFileObject.self, from: Data("""
        {
          "file_id": "voice-file-2",
          "file_name": "recording.m4a",
          "mime_type": "audio/mp4",
          "size_bytes": 1024,
          "content_type": "voice",
          "media_category": "audio",
          "kind": "voice"
        }
        """.utf8))

        XCTAssertEqual(file.contentType, "voice")
        XCTAssertEqual(file.mediaCategory, "audio")
        XCTAssertEqual(file.kind, "voice")
    }

    func testRemoteFavoriteAssetsResponseDecodesContractFields() throws {
        let result = try JSONDecoder().decode(RemoteFavoriteAssetsResponse.self, from: Data("""
        {
          "items": [
            {
              "tenant_id": "tenant-1",
              "message_id": "msg-1",
              "channel_id": "group-1",
              "channel_type": "group",
              "channel_seq": "42",
              "from_uid": "WXT000001",
              "sender_uid": "WXT000001",
              "content_type": "file",
              "payload": {
                "file_id": "file-1",
                "file_name": "users_import_template.csv",
                "mime_type": "text/csv",
                "size_bytes": 2048,
                "media_category": "spreadsheet"
              },
              "status": "sent",
              "created_at": "2026-07-04T09:10:11Z",
              "favorited_at": "2026-07-04T09:12:13Z",
              "favorite_version": "7",
              "category": "spreadsheet",
              "display_text": "users_import_template.csv",
              "cursor": "opaque-cursor-1"
            }
          ],
          "next_cursor": "opaque-cursor-2",
          "has_more": true
        }
        """.utf8))

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].tenantID, "tenant-1")
        XCTAssertEqual(result.items[0].messageID, "msg-1")
        XCTAssertEqual(result.items[0].channelSeq, 42)
        XCTAssertEqual(result.items[0].favoriteVersion, 7)
        XCTAssertEqual(result.items[0].payload["file_name"]?.stringValue, "users_import_template.csv")
        XCTAssertEqual(result.items[0].category, "spreadsheet")
        XCTAssertEqual(result.nextCursor, "opaque-cursor-2")
        XCTAssertTrue(result.hasMore)
    }

    func testFavoriteAssetCategoryMappingKeepsFileTabOrder() {
        XCTAssertEqual(FavoriteAssetCategory.displayOrder.map(\.title), ["全部", "PDF", "图片", "视频", "表格", "文档", "压缩包", "音频"])
        XCTAssertEqual(FavoriteAssetCategory(displayTitle: "表格").requestValue, "spreadsheet")
        XCTAssertEqual(FavoriteAssetCategory(displayTitle: "文档").requestValue, "document")
        XCTAssertEqual(FavoriteAssetCategory(serverValue: ""), .all)
        XCTAssertEqual(FavoriteAssetCategory(serverValue: "audio").title, "音频")
    }

    func testRemoteGroupDissolvePreviewDecodesCanonicalFields() throws {
        let result = try JSONDecoder().decode(RemoteGroupDissolvePreview.self, from: Data("""
        {
          "group_id": "group-1",
          "member_count": 8,
          "affected_members": 8,
          "confirmation_required": true,
          "confirmation_mode": "button",
          "effects": ["group_hidden", "conversations_removed"]
        }
        """.utf8))

        XCTAssertEqual(result.groupID, "group-1")
        XCTAssertEqual(result.memberCount, 8)
        XCTAssertEqual(result.affectedMembers, 8)
        XCTAssertTrue(result.confirmationRequired)
        XCTAssertEqual(result.confirmationMode, "button")
        XCTAssertEqual(result.effects, ["group_hidden", "conversations_removed"])
    }

    @MainActor
    func testGroupLifecycleErrorCodesUseSafeCopy() {
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_owner_cannot_leave"), "群主需先转让群主或解散该群")
        // WDT_RECEIPT_DETAIL_SCOPE_20261023: generic denial must never imply dissolution.
        XCTAssertNil(AppState.groupLifecycleUserMessage(for: "permission_denied"))
        XCTAssertNil(AppState.groupLifecycleUserMessage(for: "permission_denied 没有权限查看或执行该操作"))
        XCTAssertNil(AppState.groupLifecycleUserMessage(for: "read_receipt_details_forbidden"))
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_dissolve_permission_denied"), "只有群主可以解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "confirmation_required"), "请确认后再解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "invalid_confirmation"), "请确认后再解散该群")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_already_dissolved"), "该群聊不存在或已解散")
        XCTAssertEqual(AppState.groupLifecycleUserMessage(for: "group_dissolve_in_progress"), "群聊正在解散中，请稍后")
    }

    // WDT_RECEIPT_DETAIL_SCOPE_20261023
    @MainActor
    func testReceiptPermissionErrorsHaveSeparateOperationContext() {
        let state = AppState()
        let generic = IMAPIError.businessForbidden(code: "permission_denied", message: "没有权限查看或执行该操作", error: nil)
        XCTAssertEqual(state.userFacingError(generic), "无权限执行该操作")
        XCTAssertEqual(AppState.groupDissolvePermissionMessage(for: generic), "只有群主可以解散该群")
        XCTAssertTrue(AppState.isReadReceiptDetailPermissionDenied(generic))
        XCTAssertTrue(AppState.isReadReceiptDetailPermissionDenied(IMAPIError.httpStatus(403, message: "unknown")))
        XCTAssertFalse(AppState.isReadReceiptDetailPermissionDenied(IMAPIError.unauthorized("expired")))
        XCTAssertFalse(AppState.isReadReceiptDetailPermissionDenied(IMAPIError.httpStatus(404, message: "not found")))
        XCTAssertFalse(AppState.isReadReceiptDetailPermissionDenied(IMAPIError.businessForbidden(code: "read_receipts_not_enabled", message: "", error: nil)))
        XCTAssertNil(AppState.groupDissolvePermissionMessage(for: IMAPIError.businessForbidden(code: "read_receipt_details_forbidden", message: "", error: nil)))
    }
}
