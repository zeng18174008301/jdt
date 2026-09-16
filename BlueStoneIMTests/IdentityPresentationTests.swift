import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import BlueStoneIM

final class IdentityPresentationTests: XCTestCase {
    private let golden = #"""
    {
      "schema":"user_summary.v2",
      "contract_version":1,
      "user_revision":9,
      "generations":{"identity":41,"certification":7},
      "im_uid":"WXT00000001",
      "user_id":"WXT00000001",
      "display_name":"王总",
      "display_name_source":"remark",
      "raw_nickname":"王小明",
      "avatar":{
        "url":"/api/tenant/static/avatars/default-users/v2/a-0001.webp",
        "version":"default-avatar-v2:<manifest-hash>:a-0001",
        "source":"system_default",
        "catalog_version":"v2"
      },
      "certification":{"verified":true,"label":"企业导师","style":"tenant_certified_v1","revision":3}
    }
    """#

    func testUserSummaryV2GoldenRoundTripHasExactPublicFields() throws {
        let summary = try JSONDecoder().decode(UserSummaryV2.self, from: Data(golden.utf8))

        XCTAssertEqual(summary.schema, "user_summary.v2")
        XCTAssertEqual(summary.contractVersion, 1)
        XCTAssertEqual(summary.userRevision, 9)
        XCTAssertEqual(summary.generations, .init(identity: 41, certification: 7))
        XCTAssertEqual(summary.imUID, "WXT00000001")
        XCTAssertEqual(summary.userID, "WXT00000001")
        XCTAssertEqual(summary.displayName, "王总")
        XCTAssertEqual(summary.displayNameSource, "remark")
        XCTAssertEqual(summary.rawNickname, "王小明")
        XCTAssertEqual(summary.avatar.catalogVersion, "v2")
        XCTAssertEqual(summary.certification?.label, "企业导师")

        let encoded = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "schema", "contract_version", "user_revision", "generations",
                "im_uid", "user_id", "display_name", "display_name_source",
                "raw_nickname", "avatar", "certification"
            ]
        )
    }

    func testUserSummaryV2RejectsSensitiveOrPrivilegedLeakage() {
        for forbidden in [
            "analytics", "analytics_availability", "analytics_generation",
            "analytics_metrics", "admin_notes", "audit_actor", "behavior_analysis", "city",
            "internal_capabilities", "internal_role", "internal_view", "ip",
            "key_account", "key_account_generation", "last_login",
            "last_login_city", "last_login_ip", "login_history",
            "merchant_admin_note", "note", "operator_private_note", "phone",
            "phone_binding", "phone_masked", "phone_possession", "phone_verified",
            "phone_verified_at", "private_note", "private_remark", "real_name", "real_name_status",
            "real_name_verified", "real_name_reject_reason",
            "role_binding", "verification"
        ] {
            let leaked = golden.replacingOccurrences(
                of: #""schema":"user_summary.v2","#,
                with: #""schema":"user_summary.v2","\#(forbidden)":"forbidden","#
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(UserSummaryV2.self, from: Data(leaked.utf8)),
                "ordinary summary must reject \(forbidden)"
            ) {
                XCTAssertEqual($0 as? UserSummaryV2Error, .unknownField(forbidden))
            }
        }
    }

    func testUserSummaryV2RejectsNestedAndCamelCaseSensitiveLeakage() {
        let nested = golden.replacingOccurrences(
            of: #""schema":"user_summary.v2","#,
            with: #""schema":"user_summary.v2","future_safe":{"phoneMasked":"forbidden"},"#
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(UserSummaryV2.self, from: Data(nested.utf8))
        ) {
            XCTAssertEqual($0 as? UserSummaryV2Error, .unknownField("phoneMasked"))
        }
    }

    func testCombinedPresentationUsesFixedNonConflictingSlotsAndAccessibleName() throws {
        let summary = try JSONDecoder().decode(UserSummaryV2.self, from: Data(golden.utf8))
        let presentation = IdentityPresentation(
            summary: summary,
            context: IdentityPresentationContext(
                online: true,
                groupRole: "群主",
                status: "已静音",
                trailing: "2分钟前",
                explicitDecorations: [
                    IdentityPresentationDecoration(
                        slot: .avatarLowerRight,
                        value: "extension-avatar-marker",
                        accessibilityLabel: "扩展头像标记"
                    ),
                    IdentityPresentationDecoration(
                        slot: .afterNameCertificationPill,
                        value: "extension-label",
                        accessibilityLabel: "扩展名称标记"
                    )
                ]
            )
        )

        XCTAssertNil(presentation.onlineDecoration)
        XCTAssertEqual(presentation.certificationDecoration?.slot, .avatarLowerRight)
        XCTAssertEqual(
            presentation.certificationPill?.slot,
            .afterNameCertificationPill
        )
        XCTAssertEqual(presentation.groupRoleDecoration?.slot, .afterNameGroupRole)
        XCTAssertEqual(presentation.statusDecoration?.slot, .metadataStatus)
        XCTAssertEqual(presentation.trailingDecoration?.slot, .trailing)
        XCTAssertEqual(presentation.certificationPill?.value, "extension-label")
        XCTAssertTrue(presentation.accessibilityName.contains("王总"))
        XCTAssertTrue(presentation.accessibilityName.contains("群角色：群主"))
        XCTAssertTrue(presentation.accessibilityName.contains("状态：已静音"))
        XCTAssertFalse(presentation.accessibilityName.contains("在线"))
        XCTAssertEqual(
            presentation.afterNameDecorations.map(\.slot),
            [
                .afterNameCertificationPill,
                .afterNameGroupRole
            ]
        )
    }

    func testCertificationDataDoesNotDerivePresentationWithoutExplicitDecoration() throws {
        let summary = try JSONDecoder().decode(UserSummaryV2.self, from: Data(golden.utf8))
        XCTAssertNotNil(summary.certification)

        let presentation = IdentityPresentation(summary: summary)

        XCTAssertNil(presentation.certificationDecoration)
        XCTAssertNil(presentation.certificationPill)
        XCTAssertEqual(presentation.accessibilityName, "王总")
    }

    func testUnknownSafeFieldsAreIgnoredForAdditiveV1Compatibility() throws {
        let extended = golden
            .replacingOccurrences(
                of: #""schema":"user_summary.v2","#,
                with: #""schema":"user_summary.v2","future_safe":"value","#
            )
            .replacingOccurrences(
                of: #""identity":41,"certification":7"#,
                with: #""identity":41,"certification":7,"future_generation":8"#
            )
            .replacingOccurrences(
                of: #""catalog_version":"v2""#,
                with: #""catalog_version":"v2","future_avatar":"value""#
            )
            .replacingOccurrences(
                of: #""revision":3"#,
                with: #""revision":3,"future_certification":"value""#
            )

        let summary = try JSONDecoder().decode(
            UserSummaryV2.self,
            from: Data(extended.utf8)
        )

        XCTAssertEqual(summary.displayName, "王总")
        XCTAssertEqual(summary.generations.identity, 41)
        XCTAssertEqual(summary.avatar.catalogVersion, "v2")
        XCTAssertEqual(summary.certification?.revision, 3)
    }

    func testCertificationFamilyAndObjectAreOptional() throws {
        let withoutCertification = #"""
        {
          "schema":"user_summary.v2",
          "contract_version":1,
          "user_revision":9,
          "generations":{"identity":41},
          "im_uid":"WXT00000001",
          "user_id":"WXT00000001",
          "display_name":"王总",
          "display_name_source":"remark",
          "raw_nickname":"王小明",
          "avatar":{
            "url":"/api/tenant/static/avatars/default-users/v2/a-0001.webp",
            "version":"default-avatar-v2:<manifest-hash>:a-0001",
            "source":"system_default",
            "catalog_version":"v2"
          }
        }
        """#

        let summary = try JSONDecoder().decode(
            UserSummaryV2.self,
            from: Data(withoutCertification.utf8)
        )

        XCTAssertEqual(summary.generations.identity, 41)
        XCTAssertNil(summary.generations.certification)
        XCTAssertNil(summary.certification)
        XCTAssertNil(IdentityPresentation(summary: summary).certificationDecoration)
        XCTAssertNil(IdentityPresentation(summary: summary).certificationPill)
    }

    @MainActor
    func testViewerPrivateRemarkPresentationUpdatesClearsAliasesAndDoesNotLeakAcrossViewers() {
        let contact = makeRemarkContractUser(
            id: "uid-contact",
            userID: "WXT00000002",
            username: "contact002",
            name: "公共昵称"
        )
        let groupProjection = makeRemarkContractUser(
            id: "uid-contact",
            userID: "WXT00000002",
            username: "",
            name: "群昵称"
        )
        let viewerA = AppState(apiContextOverride: remarkContractContext(tenantID: "tenant-a", imUID: "viewer-a"))
        viewerA.currentUser = makeRemarkContractUser(id: "viewer-a", name: "查看者 A")
        viewerA.contacts = [contact]

        viewerA.contactRemarks = ["WXT00000002": "客户王总"]
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: contact), "客户王总")
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: groupProjection), "客户王总")

        viewerA.contactRemarks = ["uid-contact": "项目负责人"]
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: contact), "项目负责人")

        viewerA.contactRemarks = [:]
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: contact), "公共昵称")
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: groupProjection), "群昵称")

        viewerA.contactRemarks = ["viewer-a": "不应显示的本人备注"]
        XCTAssertEqual(viewerA.remarkPreferredDisplayName(for: viewerA.currentUser), "查看者 A")

        let viewerB = AppState(apiContextOverride: remarkContractContext(tenantID: "tenant-a", imUID: "viewer-b"))
        viewerB.currentUser = makeRemarkContractUser(id: "viewer-b", name: "查看者 B")
        viewerB.contacts = [contact]
        XCTAssertEqual(viewerB.remarkPreferredDisplayName(for: contact), "公共昵称")
    }

    func testSystemNotificationPayloadIgnoresViewerPrivateRemarkFields() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-1",
            "aggregate_id": "conversation-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "scope-a",
            "title": "私有备注",
            "remark": "私有备注"
        ]))

        XCTAssertEqual(payload.title, "收到新消息通知")
    }

    func testOtherUserAvatarPreviewPolicyOnlyAdmitsCustomOtherUserImages() {
        let custom = makeAvatarPreviewUser(avatarURL: "/api/tenant/avatar/peer-1")
        XCTAssertEqual(
            OtherUserAvatarPreviewPolicy.source(for: custom, isSelf: false, isCancelled: false),
            "/api/tenant/avatar/peer-1"
        )
        XCTAssertNil(OtherUserAvatarPreviewPolicy.source(for: custom, isSelf: true, isCancelled: false))
        XCTAssertNil(OtherUserAvatarPreviewPolicy.source(for: custom, isSelf: false, isCancelled: true))
        XCTAssertNil(
            OtherUserAvatarPreviewPolicy.source(
                for: makeAvatarPreviewUser(avatarURL: ""),
                isSelf: false,
                isCancelled: false
            )
        )
        XCTAssertNil(
            OtherUserAvatarPreviewPolicy.source(
                for: makeAvatarPreviewUser(
                    avatarURL: "/api/tenant/static/avatars/default-users-v2/01/pb.webp"
                ),
                isSelf: false,
                isCancelled: false
            )
        )
        XCTAssertNil(
            OtherUserAvatarPreviewPolicy.source(
                for: makeAvatarPreviewUser(
                    avatarURL: "/api/tenant/avatar/peer-1",
                    avatarVersion: "default-avatar-v2:catalog:01"
                ),
                isSelf: false,
                isCancelled: false
            )
        )
    }

    func testOtherUserAvatarPreviewPolicyPreservesSignedBestAvailableURL() throws {
        let signed = "https://cdn.example/avatar/peer?X-Amz-Signature=secret&X-Amz-Credential=scope"
        XCTAssertEqual(
            OtherUserAvatarPreviewPolicy.source(
                for: makeAvatarPreviewUser(avatarURL: signed, avatarVersion: "v9"),
                isSelf: false,
                isCancelled: false
            ),
            signed
        )
    }

    func testOtherUserAvatarPreviewUsesFullScreenContainAndExistingDismissalContract() throws {
        let contacts = try sourceText(relativePath: "../BlueStoneIM/ContactsViews.swift")
        let profile = try sourceSection(contacts, startingAt: "struct UserProfileView")
        let preview = try sourceSection(contacts, startingAt: "struct UserAvatarPreviewSheet")

        XCTAssertTrue(profile.contains("OtherUserAvatarPreviewPolicy.source"))
        XCTAssertTrue(profile.contains("other_user_avatar_preview_button"))
        XCTAssertTrue(profile.contains(".fullScreenCover(isPresented: $showAvatarPreview)"))
        XCTAssertTrue(preview.contains(".scaledToFit()"))
        XCTAssertTrue(preview.contains("AttachmentImagePreviewDismissalPolicy"))
        XCTAssertTrue(preview.contains(".accessibilityAction(.escape)"))
        XCTAssertTrue(preview.contains("点击遮罩关闭头像预览"))
        XCTAssertTrue(preview.contains("头像加载失败"))
        XCTAssertTrue(preview.contains("other_user_avatar_preview_retry_button"))
        XCTAssertTrue(preview.contains("maxPixelSize: nil"))
    }

    func testRemarkPresentationSurfacesUseLiveViewerResolver() throws {
        let contacts = try sourceText(relativePath: "../BlueStoneIM/ContactsViews.swift")
        let chat = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let conversations = try sourceText(relativePath: "../BlueStoneIM/ConversationViews.swift")

        for symbol in [
            "private struct DepartmentMemberInviteSheet",
            "private struct ContactDirectoryRow",
            "struct GroupMemberManagementView",
            "private struct GroupMemberRoleRow",
            "private struct GroupMemberActionSheet",
            "private struct GroupInviteMembersSheet",
            "private struct GroupMuteListRow"
        ] {
            XCTAssertTrue(
                try sourceSection(contacts, startingAt: symbol).contains("remarkPreferredDisplayName"),
                "\(symbol) must resolve the current viewer's live remark"
            )
        }
        let profileView = try sourceSection(
            contacts,
            startingAt: "struct UserProfileView"
        )
        XCTAssertTrue(profileView.contains("state.liveProfileUser"))
        XCTAssertTrue(profileView.contains("state.userProfileDisplayName"))
        XCTAssertTrue(profileView.contains("liveUser.displayAvatarURL"))
        XCTAssertFalse(profileView.contains("state.visibleLastLoginText(for: liveUser)"))
        XCTAssertTrue(contacts.contains(".onChangeCompat(of: state.contactRemarks)"))

        for symbol in [
            "private struct UserQuickActionOverlay",
            "private struct ContactCardPickerSheet",
            "private struct ReceiptRow",
            "private struct ReactionDetailRow",
            "private struct MentionSuggestionPanel"
        ] {
            XCTAssertTrue(
                try sourceSection(chat, startingAt: symbol).contains("remarkPreferredDisplayName"),
                "\(symbol) must resolve the current viewer's live remark"
            )
        }

        let searchRow = try sourceSection(conversations, startingAt: "private struct TenantSearchResultRow")
        XCTAssertTrue(searchRow.contains("contactDisplayName"))
        XCTAssertTrue(searchRow.contains("remarkPreferredDisplayName"))
        for symbol in ["struct CreateGroupSheet", "private struct StartDirectChatSheet"] {
            let section = try sourceSection(conversations, startingAt: symbol)
            XCTAssertTrue(section.contains("remarkPreferredDisplayName"))
            XCTAssertTrue(section.contains("withName"))
        }
        XCTAssertTrue(conversations.contains("\"会话 \\(displayTitle)\""))
        XCTAssertTrue(chat.contains("let replacement = \"@\\(mentionVisibleDisplayName(for: user)) \""))
    }

    @MainActor
    func testUserProfileLiveResolverRefreshesExactUIDAndNeverRemarksSelf() {
        let context = remarkContractContext(
            tenantID: "tenant-a",
            imUID: "viewer-a"
        )
        let state = AppState(apiContextOverride: context)
        state.currentUser = makeRemarkContractUser(
            id: "viewer-a",
            name: "查看者公共昵称"
        )
        let seed = IMUser(
            id: "uid-contact",
            userID: "WXT00000002",
            username: "contact002",
            name: "旧公共昵称",
            title: "",
            department: "旧部门",
            phone: "",
            email: "",
            status: "离线",
            enterprise: "测试企业",
            avatarSeed: 1,
            avatarURL: "https://tenant.example/old.png",
            avatarVersion: "old",
            avatarUpdatedAt: "old",
            badges: []
        )
        let refreshed = IMUser(
            id: "uid-contact",
            userID: "WXT00000002",
            username: "contact002",
            name: "新公共昵称",
            title: "",
            department: "新部门",
            phone: "138****0000",
            email: "",
            status: "在线",
            lastLoginAt: "刚刚",
            enterprise: "测试企业",
            avatarSeed: 1,
            avatarURL: "https://tenant.example/new.png",
            avatarVersion: "new-v2",
            avatarUpdatedAt: "new-at",
            badges: []
        )
        state.contacts = [refreshed]
        state.contactRemarks = [
            "WXT00000002": "私有备注",
            "viewer-a": "本人私有备注"
        ]

        let live = state.liveProfileUser(for: seed)
        XCTAssertEqual(live.name, "新公共昵称")
        XCTAssertEqual(live.status, "在线")
        XCTAssertEqual(live.avatarURL, "https://tenant.example/new.png")
        XCTAssertEqual(live.avatarVersion, "new-v2")
        XCTAssertEqual(state.userProfileDisplayName(for: seed), "私有备注")
        XCTAssertEqual(
            state.userProfileDisplayName(for: state.currentUser),
            "查看者公共昵称"
        )
    }

    func testRemarkEditorWaitsForAuthoritativeSuccessAndKeepsRetryErrorVisible() throws {
        let contacts = try sourceText(relativePath: "../BlueStoneIM/ContactsViews.swift")
        let section = try sourceSection(
            contacts,
            startingAt: "private struct ContactRemarkEditSheet"
        )
        XCTAssertTrue(section.contains("@State private var isSaving"))
        XCTAssertTrue(section.contains("state.setContactRemark(remark, for: user) { result in"))
        XCTAssertTrue(section.contains("case .success"))
        XCTAssertTrue(section.contains("case .failure(let failure)"))
        XCTAssertTrue(section.contains("contact_remark_save_error"))
        XCTAssertTrue(section.contains(".interactiveDismissDisabled(isSaving)"))
    }

    func testUploadedAvatarMayOmitCatalogVersionAndRoundTripsAsOmitted() throws {
        var withoutCatalogObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any]
        )
        var uploadedAvatar = try XCTUnwrap(withoutCatalogObject["avatar"] as? [String: Any])
        uploadedAvatar["source"] = "user_upload"
        uploadedAvatar.removeValue(forKey: "catalog_version")
        withoutCatalogObject["avatar"] = uploadedAvatar
        let withoutCatalog = try JSONSerialization.data(withJSONObject: withoutCatalogObject)
        let summary = try JSONDecoder().decode(
            UserSummaryV2.self,
            from: withoutCatalog
        )
        let avatar = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))
                as? [String: Any])?["avatar"] as? [String: Any]
        )

        XCTAssertNil(summary.avatar.catalogVersion)
        XCTAssertFalse(avatar.keys.contains("catalog_version"))
    }

    func testRejectsInactiveCertificationInvalidSystemCatalogAndMissingRenderFields() throws {
        let inactive = golden.replacingOccurrences(
            of: #""verified":true"#,
            with: #""verified":false"#
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(UserSummaryV2.self, from: Data(inactive.utf8))
        ) {
            XCTAssertEqual($0 as? UserSummaryV2Error, .invalidCertification)
        }

        var missingSystemCatalogObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any]
        )
        var missingSystemAvatar = try XCTUnwrap(
            missingSystemCatalogObject["avatar"] as? [String: Any]
        )
        missingSystemAvatar.removeValue(forKey: "catalog_version")
        missingSystemCatalogObject["avatar"] = missingSystemAvatar
        let missingSystemCatalog = try JSONSerialization.data(
            withJSONObject: missingSystemCatalogObject
        )
        let wrongSystemCatalog = golden.replacingOccurrences(
            of: #""catalog_version":"v2""#,
            with: #""catalog_version":"v3""#
        )
        for invalid in [missingSystemCatalog, Data(wrongSystemCatalog.utf8)] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(UserSummaryV2.self, from: invalid)
            ) {
                XCTAssertEqual($0 as? UserSummaryV2Error, .invalidAvatar)
            }
        }

        for replacement in [
            (#""display_name_source":"remark""#, #""display_name_source":"""#),
            (#""url":"/api/tenant/static/avatars/default-users/v2/a-0001.webp""#, #""url":"""#),
            (#""version":"default-avatar-v2:<manifest-hash>:a-0001""#, #""version":"""#),
            (#""source":"system_default""#, #""source":"""#)
        ] {
            let invalid = golden.replacingOccurrences(
                of: replacement.0,
                with: replacement.1
            )
            XCTAssertThrowsError(
                try JSONDecoder().decode(UserSummaryV2.self, from: Data(invalid.utf8))
            )
        }
    }

    func testContactUserNumberUsesOnlyTrimmedAuthoritativeUserID() {
        XCTAssertEqual(contactAuthoritativeUserNumber(userID: "  WXT00001234  "), "WXT00001234")
        XCTAssertNil(contactAuthoritativeUserNumber(userID: "  \n "))
    }

    func testContactDirectoryAndSharedRowsKeepUserNumberBelowNameWithoutReplacingDepartment() throws {
        let contacts = try sourceText(relativePath: "../BlueStoneIM/ContactsViews.swift")
        for symbol in ["private struct ContactDirectoryRow", "struct ContactRow"] {
            let row = try sourceSection(contacts, startingAt: symbol)
            XCTAssertTrue(row.contains("contactAuthoritativeUserNumber(userID: user.userID)"), symbol)
            XCTAssertTrue(row.contains("font(.caption2.weight(.semibold))"), symbol)
            XCTAssertTrue(row.contains("foregroundStyle(IMColor.muted)"), symbol)
            XCTAssertTrue(row.contains("lineLimit(1)"), symbol)
            XCTAssertTrue(row.contains("truncationMode(.middle)"), symbol)
            XCTAssertTrue(row.contains("layoutPriority(1)"), symbol)
        }
        let directory = try sourceSection(contacts, startingAt: "private struct ContactDirectoryRow")
        XCTAssertTrue(directory.contains("state.departmentSummary(for: user)"))
        XCTAssertTrue(contacts.contains("accessibilityContactUserNumber(user.userID)"))
    }

    @MainActor
    func testSharedContactRowRendersLongAuthoritativeNumberAtPhoneAndDesktopWidthsWithDynamicType() {
        let user = makeRemarkContractUser(
            id: "contact-layout-user",
            userID: "WXT-00000000000000000000000000000000000001",
            name: "这是一条非常非常长的联系人昵称用于验证布局不会挤掉权威用户编号"
        )
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-contact-layout", imUID: "viewer-contact-layout")
        )
        for width in [390.0, 1024.0] {
            let root = ContactRow(user: user)
                .environmentObject(state)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: width, height: 240))
            let image = hostedSnapshotImage(hosted)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "contact-user-number-axxxl-\(Int(width))pt"))
            hosted.window.isHidden = true
        }
    }

    func testReturnToBottomControlIsAdaptiveAccessibleAndDoesNotResizeTimeline() throws {
        let chat = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let shell = try sourceSection(chat, startingAt: "private var unlockedBody: some View")
        XCTAssertTrue(shell.contains("ZStack(alignment: .top)"))
        XCTAssertTrue(shell.contains("ReturnToBottomBar(count: boundedPendingUnreadCount)"))
        let control = try sourceSection(chat, startingAt: "private struct ReturnToBottomBar")
        XCTAssertTrue(control.contains("font(.callout.weight(.bold))"))
        XCTAssertTrue(control.contains("minHeight: 44"))
        XCTAssertTrue(control.contains("lineLimit(2)"))
        XCTAssertTrue(control.contains("chat_return_to_bottom_button"))
        XCTAssertTrue(control.contains("accessibilityLabel(accessibilityTitle)"))
        XCTAssertTrue(control.contains("accessibilityHint"))
    }

    func testChatTranscriptOwnsKeyboardDismissalWithoutWrappingComposerControls() throws {
        let chat = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let timeline = try sourceSection(chat, startingAt: "private func messageTimeline(")
        XCTAssertTrue(timeline.contains("simultaneousGesture(messageTranscriptTapGesture)"))
        XCTAssertTrue(timeline.contains("chatScrollDismissesKeyboardInteractively()"))
        XCTAssertTrue(timeline.contains("dismissChatKeyboardFromTranscript(trigger: .tap)"))
        XCTAssertTrue(timeline.contains("dismissChatKeyboardFromTranscript(trigger: .longPress)"))
        let composer = try sourceSection(chat, startingAt: "struct ChatComposer: View")
        XCTAssertFalse(composer.contains("messageTranscriptTapGesture"))
        XCTAssertFalse(composer.contains("messageTranscriptDragGesture"))
    }

    @MainActor
    func testImmediateMuteListProjectionMergesSelectedIdentityAndReasonIntoSparseResponse() throws {
        let remote = try JSONDecoder().decode(
            RemoteGroupMuteListItem.self,
            from: Data(#"{"group_id":"group-1"}"#.utf8)
        )
        let selected = IMUser(
            id: "im-uid-1",
            userID: "user-1",
            username: "member001",
            name: "已选择成员",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 7,
            badges: []
        )
        let state = AppState(apiContextOverride: IMAPIContext(
            platformToken: nil,
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "operator-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "device-1"
        ))

        let item = state.groupMuteListItem(
            from: remote,
            fallbackGroupID: "group-1",
            fallbackTarget: selected,
            fallbackTargetUID: selected.id,
            fallbackReason: "违反群规"
        )

        XCTAssertEqual(item.targetUID, "im-uid-1")
        XCTAssertEqual(item.targetUserID, "user-1")
        XCTAssertEqual(item.targetUsername, "member001")
        XCTAssertEqual(item.targetNickname, "已选择成员")
        XCTAssertEqual(item.reason, "违反群规")
        XCTAssertEqual(item.targetDisplayName, "已选择成员")
        XCTAssertEqual(item.targetDisplayID, "user-1")
    }

    func testMessageBubbleGroupSenderMetadataUsesOneHorizontalRow() throws {
        let source = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let rendererStart = try XCTUnwrap(
            source.range(of: "private func senderNameWithRole(")?.lowerBound
        )
        let rendererTail = source[rendererStart...]
        let rendererEnd = try XCTUnwrap(
            rendererTail.range(of: "private var senderUser: IMUser?")?.lowerBound
        )
        let renderer = rendererTail[..<rendererEnd]

        XCTAssertTrue(renderer.contains("HStack(alignment: .firstTextBaseline"))
        XCTAssertFalse(renderer.contains("VStack("))
        XCTAssertTrue(renderer.contains(".lineLimit(1)"))
        XCTAssertTrue(renderer.contains(".truncationMode(.tail)"))
        XCTAssertTrue(renderer.contains(".layoutPriority(0)"))
        XCTAssertTrue(renderer.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(renderer.contains(".layoutPriority(1)"))

        let nickname = try XCTUnwrap(renderer.range(of: "Text(name)"))
        let certification = try XCTUnwrap(renderer.range(of: "CertificationPillView("))
        let role = try XCTUnwrap(renderer.range(of: "ChatSenderRoleIcon(role: role)"))
        XCTAssertLessThan(nickname.lowerBound, certification.lowerBound)
        XCTAssertLessThan(certification.lowerBound, role.lowerBound)

        let badgeStart = try XCTUnwrap(
            source.range(of: "private struct ChatSenderRoleIcon: View")?.lowerBound
        )
        let badgeTail = source[badgeStart...]
        let badgeEnd = try XCTUnwrap(
            badgeTail.range(of: "private func groupRoleUser(")?.lowerBound
        )
        let badge = badgeTail[..<badgeEnd]
        XCTAssertTrue(badge.contains("Text(role.title)"))
        XCTAssertTrue(badge.contains(".lineLimit(1)"))
        XCTAssertTrue(badge.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(badge.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(badge.contains(".accessibilityLabel(role.title)"))

        let accessibleName = try XCTUnwrap(renderer.range(of: "name,"))
        let accessibleCertification = try XCTUnwrap(
            renderer.range(of: "state.certificationPresentation(")
        )
        let accessibleRole = try XCTUnwrap(renderer.range(of: "role?.title"))
        XCTAssertLessThan(accessibleName.lowerBound, accessibleCertification.lowerBound)
        XCTAssertLessThan(accessibleCertification.lowerBound, accessibleRole.lowerBound)

        let roleProjectionStart = try XCTUnwrap(
            source.range(of: "private var senderGroupRole: ChatSenderGroupRole?")?.lowerBound
        )
        let roleProjectionTail = source[roleProjectionStart...]
        let roleProjectionEnd = try XCTUnwrap(
            roleProjectionTail.range(of: "private var displayMessageText: String")?.lowerBound
        )
        let roleProjection = roleProjectionTail[..<roleProjectionEnd]
        XCTAssertTrue(roleProjection.contains("state.group(forConversationID: conversationID)"))
        XCTAssertTrue(roleProjection.contains("return .owner"))
        XCTAssertTrue(roleProjection.contains("return .admin"))
        XCTAssertTrue(roleProjection.contains("return nil"))
    }

    func testChatHeaderTitleDecisionUsesOnlyResolvedDirectPeerIdentity() {
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: " 客户王总 ",
                conversationTitle: "查看者本人"
            ),
            "客户王总"
        )
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: nil,
                conversationTitle: "查看者本人"
            ),
            ChatHeaderTitleDecision.safeDirectFallback
        )
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .group,
                resolvedPeerDisplayName: "不应使用的私聊对象",
                conversationTitle: " 产品研发群 "
            ),
            "产品研发群"
        )
    }

    @MainActor
    func testDirectChatHeaderTitleUsesViewerScopedRemarkWithoutCrossAccountLeakage() throws {
        let peer = makeRemarkContractUser(
            id: "peer-im-uid",
            userID: "WXT00000002",
            username: "peer002",
            name: "公共昵称"
        )
        let conversation = Conversation(
            id: "viewer-a:peer-im-uid",
            title: "查看者本人",
            subtitle: "",
            kind: .direct,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: nil,
            accentHex: 0,
            participants: [
                makeRemarkContractUser(id: "viewer-a", name: "查看者本人"),
                peer
            ],
            messages: []
        )

        let viewerA = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-a", imUID: "viewer-a")
        )
        viewerA.currentUser = makeRemarkContractUser(id: "viewer-a", name: "查看者本人")
        viewerA.contacts = [peer]
        viewerA.contactRemarks = ["WXT00000002": "A 的私有备注"]
        let viewerAPeer = try XCTUnwrap(viewerA.directConversationProfilePeer(for: conversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: conversation.kind,
                resolvedPeerDisplayName: viewerA.remarkPreferredDisplayName(for: viewerAPeer),
                conversationTitle: conversation.title
            ),
            "A 的私有备注"
        )

        let viewerB = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-b", imUID: "viewer-b")
        )
        viewerB.currentUser = makeRemarkContractUser(id: "viewer-b", name: "另一个查看者")
        viewerB.contacts = [peer]
        viewerB.contactRemarks = [:]
        let viewerBConversation = Conversation(
            id: "viewer-b:peer-im-uid",
            title: conversation.title,
            subtitle: conversation.subtitle,
            kind: conversation.kind,
            lastMessage: conversation.lastMessage,
            time: conversation.time,
            unread: conversation.unread,
            isPinned: conversation.isPinned,
            isMuted: conversation.isMuted,
            memberCount: conversation.memberCount,
            accentHex: conversation.accentHex,
            participants: [viewerB.currentUser, peer],
            messages: conversation.messages
        )
        let viewerBPeer = try XCTUnwrap(viewerB.directConversationProfilePeer(for: viewerBConversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: viewerBConversation.kind,
                resolvedPeerDisplayName: viewerB.remarkPreferredDisplayName(for: viewerBPeer),
                conversationTitle: viewerBConversation.title
            ),
            "公共昵称"
        )

        var selfOnlyConversation = conversation
        selfOnlyConversation.participants = [viewerA.currentUser]
        XCTAssertNil(viewerA.directConversationProfilePeer(for: selfOnlyConversation))
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: nil,
                conversationTitle: selfOnlyConversation.title
            ),
            ChatHeaderTitleDecision.safeDirectFallback
        )
    }

    func testChatComposerToolDescriptorsKeepAttachmentAndCallActionsDistinct() throws {
        let directTools = chatComposerToolDescriptors(
            allowsVoiceCall: true,
            allowsVideoCall: true
        )
        XCTAssertEqual(
            directTools.map(\.action),
            [.mediaAttachment, .fileAttachment, .voiceCall, .videoCall, .contactCard]
        )
        XCTAssertEqual(
            directTools.map(\.title),
            ["照片/视频", "文件", "通话", "视频", "名片"]
        )
        XCTAssertFalse(directTools.contains(where: { $0.title == "表情" }))

        let media = try XCTUnwrap(directTools.first(where: { $0.action == .mediaAttachment }))
        let videoCall = try XCTUnwrap(directTools.first(where: { $0.action == .videoCall }))
        XCTAssertNotEqual(media.symbol, videoCall.symbol)
        XCTAssertNotEqual(media.accessibilityIdentifier, videoCall.accessibilityIdentifier)
        XCTAssertEqual(media.accessibilityLabel, "选择照片或视频附件")
        XCTAssertEqual(videoCall.accessibilityLabel, "发起视频通话")

        let groupTools = chatComposerToolDescriptors(
            allowsVoiceCall: false,
            allowsVideoCall: false
        )
        XCTAssertEqual(
            groupTools.map(\.action),
            [.mediaAttachment, .fileAttachment, .contactCard]
        )
        XCTAssertFalse(groupTools.contains(where: { $0.action == .voiceCall || $0.action == .videoCall }))
    }

    func testDirectChatToolbarAndComposerSourceContracts() throws {
        let source = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let toolbarStart = try XCTUnwrap(source.range(of: "private var conversationHeader: some View")?.lowerBound)
        let toolbarTail = source[toolbarStart...]
        let toolbarEnd = try XCTUnwrap(toolbarTail.range(of: "\n    private var canStartVoiceCall")?.lowerBound)
        let toolbar = toolbarTail[..<toolbarEnd]

        XCTAssertTrue(toolbar.contains("ZStack"))
        XCTAssertTrue(toolbar.contains("chat_centered_conversation_title"))
        XCTAssertTrue(toolbar.contains(".lineLimit(1)"))
        XCTAssertTrue(toolbar.contains(".truncationMode(.tail)"))
        XCTAssertTrue(toolbar.contains(".frame(width: 136)"))
        XCTAssertTrue(toolbar.contains(".environment(\\.layoutDirection, .leftToRight)"))
        XCTAssertTrue(toolbar.contains("chat_search_button"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"搜索聊天记录\")"))
        XCTAssertTrue(toolbar.contains("chat_more_button"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"会话详情\")"))
        XCTAssertFalse(toolbar.contains("chat_call_button"))
        XCTAssertFalse(toolbar.contains("chat_video_call_button"))

        let composerStart = try XCTUnwrap(source.range(of: "struct ChatComposer: View")?.lowerBound)
        let composer = source[composerStart...]
        XCTAssertTrue(composer.contains("chat_emoji_toggle_button"))
        XCTAssertTrue(composer.contains("ChatExpressionPanel("))
        XCTAssertTrue(composer.contains("case .voiceCall:"))
        XCTAssertTrue(composer.contains("startVoiceCall()"))
        XCTAssertTrue(composer.contains("case .videoCall:"))
        XCTAssertTrue(composer.contains("startVideoCall()"))
        XCTAssertTrue(composer.contains("sizeCategory.isAccessibilityCategory ? 2 : 4"))
        XCTAssertTrue(composer.contains("LazyVGrid(columns: toolGridColumns"))

        let chatComposerWiringStart = try XCTUnwrap(source.range(of: "ChatComposer(\n                        conversationID: conversationID")?.lowerBound)
        let chatComposerWiringTail = source[chatComposerWiringStart...]
        let chatComposerWiringEnd = try XCTUnwrap(chatComposerWiringTail.range(of: "\n                        send:")?.lowerBound)
        let chatComposerWiring = chatComposerWiringTail[..<chatComposerWiringEnd]
        XCTAssertTrue(chatComposerWiring.contains("startVoiceCall: startVoiceCallFromConversation"))
        XCTAssertTrue(chatComposerWiring.contains("startVideoCall: startVideoCallFromConversation"))
        XCTAssertTrue(chatComposerWiring.contains("showsDisabledNotice: disabledBannerDecision.showsComposerDisabledNotice"))
        XCTAssertTrue(composer.contains("if isDisabled && showsDisabledNotice"))
    }

    func testGroupMuteBannerSourceUsesActiveAuthorityAndExistingServerBoundaryRefresh() throws {
        let chatSource = try sourceText(relativePath: "../BlueStoneIM/ChatViews.swift")
        let decisionStart = try XCTUnwrap(
            chatSource.range(of: "struct GroupMuteBannerDecision: Equatable")?.lowerBound
        )
        let decisionTail = chatSource[decisionStart...]
        let decisionEnd = try XCTUnwrap(
            decisionTail.range(of: "\nstruct ChatView: View")?.lowerBound
        )
        let decision = decisionTail[..<decisionEnd]
        XCTAssertTrue(decision.contains("if let active = group.allMuteActive"))
        XCTAssertTrue(decision.contains("guard isAuthoritativelyActive else { return nil }"))
        XCTAssertTrue(decision.contains("if group.allMuteRepairRequired"))
        XCTAssertFalse(decision.contains("Date()"))
        XCTAssertFalse(decision.contains("Calendar.current"))

        let visibilityStart = try XCTUnwrap(
            chatSource.range(of: "private var shouldShowGroupMuteStatus: Bool")?.lowerBound
        )
        let visibilityTail = chatSource[visibilityStart...]
        let visibilityEnd = try XCTUnwrap(
            visibilityTail.range(of: "private var currentGroupAnnouncement")?.lowerBound
        )
        let visibility = visibilityTail[..<visibilityEnd]
        XCTAssertTrue(visibility.contains("disabledBannerDecision.groupMuteBanner != nil"))
        XCTAssertFalse(visibility.contains("allMuteMode != .off"))

        let appStateSource = try sourceText(relativePath: "../BlueStoneIM/Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift")
        let boundaryStart = try XCTUnwrap(
            appStateSource.range(of: "func scheduleGroupMuteBoundaryRefresh")?.lowerBound
        )
        let boundaryTail = appStateSource[boundaryStart...]
        let boundaryEnd = try XCTUnwrap(
            boundaryTail.range(of: "func applyRemoteGroups")?.lowerBound
        )
        let boundary = boundaryTail[..<boundaryEnd]
        XCTAssertTrue(boundary.contains("boundary > serverTime"))
        XCTAssertTrue(boundary.contains("boundary.timeIntervalSince(serverTime)"))
        XCTAssertTrue(boundary.contains("refreshGroupBundle("))
    }

    @MainActor
    func testDirectComposerPlusGridRendersDistinctAXActionsOnSimulator() throws {
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        let root = ChatComposerUITestHarness(
            onVoiceCall: {},
            onVideoCall: {}
        )
        .environmentObject(state)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 540))
        defer { hosted.window.isHidden = true }

        let expectedIDs = [
            "chat_tool_media_attachment",
            "chat_tool_file_attachment",
            "chat_tool_voice_call",
            "chat_tool_video_call",
            "chat_tool_contact_card"
        ]
        let descriptors = chatComposerToolDescriptors(allowsVoiceCall: true, allowsVideoCall: true)
        XCTAssertEqual(descriptors.map(\.accessibilityIdentifier), expectedIDs)
        XCTAssertEqual(
            descriptors.map(\.accessibilityLabel),
            ["选择照片或视频附件", "选择文件附件", "发起语音通话", "发起视频通话", "发送联系人名片"]
        )
        XCTAssertFalse(descriptors.contains(where: { $0.title == "表情" }))

        let snapshot = hostedSnapshotImage(hosted)
        XCTAssertGreaterThan(snapshot.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(snapshot, name: "direct-plus-grid-dark-rtl-axxxl"))
    }

    @MainActor
    func testChatViewsRenderDirectTitlesAndActiveOnlyGroupBannerOnSimulator() throws {
        let directCases: [(String, String?, ColorScheme, LayoutDirection, ContentSizeCategory)] = [
            ("公共昵称", "客户王总", .light, .leftToRight, .large),
            ("无备注昵称", nil, .dark, .leftToRight, .extraExtraExtraLarge),
            ("公共昵称", "这是一条非常非常长且必须保持物理居中的客户备注名称", .dark, .rightToLeft, .accessibilityExtraExtraExtraLarge)
        ]

        for (index, fixture) in directCases.enumerated() {
            let state = directChatUIState(nickname: fixture.0, remark: fixture.1)
            let root = NavigationView {
                ChatView(conversationID: "direct-ui-chat")
            }
            .navigationViewStyle(.stack)
            .environmentObject(state)
            .environment(\.colorScheme, fixture.2)
            .environment(\.layoutDirection, fixture.3)
            .environment(\.sizeCategory, fixture.4)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 640))
            let image = hostedSnapshotImage(hosted)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "direct-chat-title-case-\(index + 1)"))
            hosted.window.isHidden = true
        }

        let memberState = groupChatUIState(role: "member", active: false, repairRequired: false)
        let memberRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .environmentObject(memberState)
        .environment(\.colorScheme, .light)
        let memberHosted = hostForSimulatorUI(memberRoot, size: CGSize(width: 320, height: 640))
        let inactiveImage = hostedSnapshotImage(memberHosted)
        add(snapshotAttachment(inactiveImage, name: "group-scheduled-inactive-banner-hidden"))
        memberHosted.window.isHidden = true

        let activeMemberState = groupChatUIState(role: "member", active: true, repairRequired: false)
        let activeMemberRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .environmentObject(activeMemberState)
        .environment(\.colorScheme, .light)
        let activeMemberHosted = hostForSimulatorUI(activeMemberRoot, size: CGSize(width: 320, height: 640))
        let activeMemberImage = hostedSnapshotImage(activeMemberHosted)
        XCTAssertNotEqual(inactiveImage.pngData(), activeMemberImage.pngData())
        add(snapshotAttachment(activeMemberImage, name: "group-scheduled-active-member-banner"))
        activeMemberHosted.window.isHidden = true

        let adminState = groupChatUIState(role: "admin", active: true, repairRequired: false)
        let adminRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .environmentObject(adminState)
        .environment(\.colorScheme, .dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let adminHosted = hostForSimulatorUI(adminRoot, size: CGSize(width: 320, height: 640))
        let adminImage = hostedSnapshotImage(adminHosted)
        XCTAssertGreaterThan(adminImage.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(adminImage, name: "group-active-admin-dark-axxxl-banner"))
        adminHosted.window.isHidden = true

        let repairState = groupChatUIState(role: "member", active: false, repairRequired: true)
        let repairRoot = NavigationView {
            ChatView(conversationID: "group-ui-chat")
        }
        .navigationViewStyle(.stack)
        .environmentObject(repairState)
        .environment(\.colorScheme, .light)
        let repairHosted = hostForSimulatorUI(repairRoot, size: CGSize(width: 320, height: 640))
        let repairImage = hostedSnapshotImage(repairHosted)
        XCTAssertGreaterThan(repairImage.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(repairImage, name: "group-repair-member-banner"))
        repairHosted.window.isHidden = true
    }

    @MainActor
    func testDirectChatToolbarRendersCenteredTitleAndActionsOnSimulator() throws {
        let remark = "这是一条非常非常长且必须保持物理居中的客户备注名称"
        let state = directChatUIState(
            nickname: "公共昵称",
            remark: remark
        )
        let root = ChatView(conversationID: "direct-ui-chat")
            .environmentObject(state)
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let hosted = hostInNavigationForSimulatorUI(root, size: CGSize(width: 320, height: 640))
        defer { hosted.window.isHidden = true }

        XCTAssertTrue(hosted.navigationController.navigationBar.isHidden)
        XCTAssertEqual(
            ChatHeaderTitleDecision.resolve(
                kind: .direct,
                resolvedPeerDisplayName: remark,
                conversationTitle: "不可信会话标题"
            ),
            remark
        )

        let image = hostedNavigationSnapshotImage(hosted)
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
        add(snapshotAttachment(image, name: "direct-toolbar-dark-rtl-axxxl-runtime-ax"))
    }

    private func makeRemarkContractUser(
        id: String,
        userID: String = "",
        username: String = "",
        name: String
    ) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
    }

    private func makeAvatarPreviewUser(
        avatarURL: String,
        avatarVersion: String = ""
    ) -> IMUser {
        IMUser(
            id: "peer-1",
            name: "顾客",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            badges: []
        )
    }

    private func remarkContractContext(tenantID: String, imUID: String) -> IMAPIContext {
        IMAPIContext(
            platformToken: nil,
            accountID: imUID,
            tenantID: tenantID,
            imUID: imUID,
            imToken: "test-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "test-device"
        )
    }

    @MainActor
    private func directChatUIState(nickname: String, remark: String?) -> AppState {
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        let viewer = makeRemarkContractUser(id: "viewer-ui", userID: "VIEWER-UI", name: "查看者")
        let peer = makeRemarkContractUser(
            id: "peer-ui",
            userID: "PEER-UI",
            username: "peer-ui",
            name: nickname
        )
        state.currentUser = viewer
        state.contacts = [peer]
        state.contactRemarks = remark.map { ["PEER-UI": $0] } ?? [:]
        state.conversationStore.conversations = [
            Conversation(
                id: "direct-ui-chat",
                title: "不可信会话标题",
                subtitle: "",
                kind: .direct,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: nil,
                accentHex: 0,
                participants: [viewer, peer],
                messages: []
            )
        ]
        return state
    }

    @MainActor
    private func groupChatUIState(role: String, active: Bool, repairRequired: Bool) -> AppState {
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        let viewer = makeRemarkContractUser(id: "viewer-ui", userID: "VIEWER-UI", name: "当前成员")
        var group = GroupInfo(
            id: "group-ui-chat",
            name: "群禁言真实界面验收",
            notice: "",
            owner: "群主",
            members: [viewer],
            admins: [],
            muted: false,
            allMuted: true,
            allMuteStart: Date(timeIntervalSince1970: 1_781_658_600),
            allMuteEnd: Date(timeIntervalSince1970: 1_781_662_200)
        )
        group.allMuteMode = .scheduled
        group.allMuteActive = active
        group.allMuteServerTime = Date(timeIntervalSince1970: 1_781_660_400)
        group.allMuteNextBoundary = group.allMuteEnd
        group.allMuteRepairRequired = repairRequired
        group.myRole = role
        state.currentUser = viewer
        state.groups = [group]
        state.conversationStore.conversations = [
            Conversation(
                id: group.id,
                title: group.name,
                subtitle: "群聊",
                kind: .group,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 1,
                accentHex: 0,
                participants: [viewer],
                messages: []
            )
        ]
        return state
    }

    private func sourceText(relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSection(_ source: String, startingAt marker: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: marker)?.lowerBound)
        let tail = source[start...]
        guard let next = tail.dropFirst(marker.count).range(of: "\nprivate struct ")?.lowerBound else {
            return tail
        }
        return tail[..<next]
    }
}

private struct ChatComposerUITestHarness: View {
    @State private var input = ""
    @State private var replyQuote: String?
    @State private var replyContext: MessageReplyContext?
    @State private var showTools = true
    @State private var showEmoji = false
    @State private var mentionAllSelected = false

    let onVoiceCall: () -> Void
    let onVideoCall: () -> Void

    var body: some View {
        VStack {
            Spacer()
            ChatComposer(
                conversationID: "direct-ui",
                input: $input,
                replyQuote: $replyQuote,
                replyContext: $replyContext,
                showTools: $showTools,
                showEmoji: $showEmoji,
                mentionAllSelected: $mentionAllSelected,
                allowsVoiceCall: true,
                allowsVideoCall: true,
                voiceCallAccessibilityHint: "语音通话测试动作",
                videoCallAccessibilityHint: "视频通话测试动作",
                startVoiceCall: onVoiceCall,
                startVideoCall: onVideoCall,
                send: { _, _, _ in }
            )
        }
    }
}

@MainActor
private struct HostedSimulatorUI<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>
}

@MainActor
private struct HostedNavigationSimulatorUI<Content: View> {
    let window: UIWindow
    let controller: UIHostingController<Content>
    let navigationController: UINavigationController
}

@MainActor
private func hostForSimulatorUI<Content: View>(
    _ root: Content,
    size: CGSize
) -> HostedSimulatorUI<Content> {
    let controller = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    controller.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: controller)
}

@MainActor
private func hostInNavigationForSimulatorUI<Content: View>(
    _ root: Content,
    size: CGSize
) -> HostedNavigationSimulatorUI<Content> {
    let controller = UIHostingController(rootView: root)
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.navigationBar.prefersLargeTitles = false
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = navigationController
    window.makeKeyAndVisible()
    navigationController.view.frame = window.bounds
    navigationController.view.setNeedsLayout()
    navigationController.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    navigationController.view.layoutIfNeeded()
    return HostedNavigationSimulatorUI(
        window: window,
        controller: controller,
        navigationController: navigationController
    )
}

@MainActor
private func hostedSnapshotImage<Content: View>(_ hosted: HostedSimulatorUI<Content>) -> UIImage {
    let renderer = UIGraphicsImageRenderer(bounds: hosted.window.bounds)
    return renderer.image { context in
        hosted.window.layer.render(in: context.cgContext)
    }
}

@MainActor
private func hostedNavigationSnapshotImage<Content: View>(
    _ hosted: HostedNavigationSimulatorUI<Content>
) -> UIImage {
    let renderer = UIGraphicsImageRenderer(bounds: hosted.window.bounds)
    return renderer.image { context in
        hosted.window.layer.render(in: context.cgContext)
    }
}

private func snapshotAttachment(_ image: UIImage, name: String) -> XCTAttachment {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
}
