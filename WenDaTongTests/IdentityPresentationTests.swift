@testable import IM4Features
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit
import XCTest
@testable import WenDaTong

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
        viewerA.setCurrentUser(makeRemarkContractUser(id: "viewer-a", name: "查看者 A")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
        viewerB.setCurrentUser(makeRemarkContractUser(id: "viewer-b", name: "查看者 B")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let contacts = try sourceText(relativePath: "../WenDaTong/Features/Contacts/ContactUserProfile.swift")
        let avatarPreview = try sourceText(relativePath: "../WenDaTong/Features/Contacts/ContactAvatarPreview.swift")
        let summary = try sourceText(relativePath: "../Sources/IM4Features/Contacts/ContactProfileSummaryContent.swift")
        let profile = try sourceSection(contacts, startingAt: "struct UserProfileView") + sourceSection(summary, startingAt: "public struct ContactProfileSummaryContent")
        let avatarPreviewContent = try sourceText(relativePath: "../Sources/IM4Features/Contacts/UserAvatarPreviewContent.swift")
        let preview = try sourceSection(avatarPreview, startingAt: "struct UserAvatarPreviewSheet")
            + sourceSection(avatarPreviewContent, startingAt: "public struct UserAvatarPreviewContent")

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
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }

    // WDT_GROUP_ROLE_BADGE_20261021
    func testGroupRoleBadgeRetainsSingleLineCapsuleBesideLongNames() throws {
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let contacts = try sourceText(relativePath: "../Sources/IM4Features/Contacts/GroupMemberRoleContent.swift")
        let badge = try sourceSection(contacts, startingAt: "public struct GroupRoleBadge")

        XCTAssertTrue(badge.contains("Image(systemName: role.symbol)"))
        XCTAssertTrue(badge.contains("Text(role.title)"))
        XCTAssertTrue(badge.contains(".lineLimit(1)"))
        XCTAssertTrue(badge.contains(".background(Capsule().fill(role.color.opacity(0.12)))"))
        XCTAssertTrue(badge.contains(".fixedSize(horizontal: true, vertical: true)"))
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }



    @MainActor
    func testUserProfileLiveResolverRefreshesExactUIDAndNeverRemarksSelf() {
        let context = remarkContractContext(
            tenantID: "tenant-a",
            imUID: "viewer-a"
        )
        let state = AppState(apiContextOverride: context)
        state.setCurrentUser(makeRemarkContractUser(
            id: "viewer-a",
            name: "查看者公共昵称"
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
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
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let contacts = try sourceText(relativePath: "../WenDaTong/Features/Contacts/ContactUserProfile.swift")
        let section = try sourceSection(
            contacts,
            startingAt: "private struct ContactRemarkEditSheet"
        )
        XCTAssertTrue(section.contains("@State private var isSaving"))
        XCTAssertTrue(section.contains("state.setContactRemark(remark, for: user) { result in"))
        XCTAssertTrue(section.contains("case .success"))
        XCTAssertTrue(section.contains("case .failure(let failure)"))
        let remarkContent = try sourceText(relativePath: "../Sources/IM4Features/Contacts/ContactRemarkEditContent.swift")
        XCTAssertTrue(remarkContent.contains("contact_remark_save_error"))
        XCTAssertTrue(section.contains(".interactiveDismissDisabled(isSaving)"))
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
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

    func makeRemarkContractUser(
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

    func remarkContractContext(tenantID: String, imUID: String) -> IMAPIContext {
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
    // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111_BEGIN
    func directChatUIState(nickname: String, remark: String?, isolatedState: AppState? = nil) -> AppState {
        let state = isolatedState ?? AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111_END
        let viewer = makeRemarkContractUser(id: "viewer-ui", userID: "VIEWER-UI", name: "查看者")
        let peer = makeRemarkContractUser(
            id: "peer-ui",
            userID: "PEER-UI",
            username: "peer-ui",
            name: nickname
        )
        state.setCurrentUser(viewer) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.contactRemarks = remark.map { ["PEER-UI": $0] } ?? [:]
        state.conversationStore.commitConversationSnapshots([
            ConversationMessageSnapshot(
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
        ])
        return state
    }

    // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_BEGIN
    @MainActor
    func isolatedGroupDirectoryUIState(tenantID: String, transport: any HTTPTransport, defaults: UserDefaults, root: URL) -> AppState {
        let context = remarkContractContext(tenantID: tenantID, imUID: "viewer-ui")
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context
        )
        let state = AppState(api: api,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        return groupChatUIState(role: "member", active: false, repairRequired: false, isolatedState: state)
    }

    @MainActor
    func groupChatUIState(role: String, active: Bool, repairRequired: Bool, isolatedState: AppState? = nil) -> AppState {
        let state = isolatedState ?? AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-ui", imUID: "viewer-ui")
        )
        // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_END
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
        // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_BEGIN
        if isolatedState == nil {
            state.setCurrentUser(viewer) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        } else {
            state.replaceCurrentUserAndProject(viewer, persistIdentity: false)
        }
        // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_END
        state.groups = [group]
        state.conversationStore.commitConversationSnapshots([
            ConversationMessageSnapshot(
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
        ])
        return state
    }

    func sourceText(relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        return try String(contentsOf: url, encoding: .utf8)
    }

    func sourceSection(_ source: String, startingAt marker: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: marker)?.lowerBound)
        let tail = source[start...]
        guard let next = tail.dropFirst(marker.count).range(of: "\nprivate struct ")?.lowerBound else {
            return tail
        }
        return tail[..<next]
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

// WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_BEGIN
@MainActor
extension IdentityPresentationTests {
    func f2Editor(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(f2Editor).first }
    func testFailedDraftRestoreBoundsOnlyInvalidUTF16Selections() throws {
        let owner = ComposerState(); owner.activate(scope: ["a", "t", "app", "u", "d"], conversationID: "A")
        let origin = try XCTUnwrap(owner.token); var sent = ComposerState.Draft(); sent.input = "old"
        let cases: [(String, NSRange, NSRange)] = [("😀", NSRange(location: 100, length: 100), NSRange(location: 6, length: 0)),
            ("😀", NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)),
            ("", NSRange(location: NSNotFound, length: NSNotFound), NSRange(location: 3, length: 0)),
            ("😀", NSRange(location: 0, length: 1), NSRange(location: 4, length: 2))]
        for item in cases {
            owner.draft.input = item.0; owner.draft.selection = item.1; owner.restoreFailedSend(sent, origin: origin)
            XCTAssertEqual(owner.draft.selection, item.2); XCTAssertNotNil(Range(owner.draft.selection, in: owner.draft.input))
        }
    }
    func testFailedDraftRestoreKeepsMountedUTF16SelectionAndContinuedInput() async throws {
        let owner = ComposerState(), scope: [String?] = ["a", "t", "app", "u", "d"]
        owner.activate(scope: scope, conversationID: "A")
        let root = ComposerStateObservation(owner: owner) {
            ComposerInputBox(text: owner.binding(\.input), dynamicHeight: .constant(42), selection: owner.binding(\.selection), isDisabled: false, onBeginEditing: {}, onEditingChanged: { _ in })
        }
        let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 300)); defer { hosted.window.isHidden = true }
        try await Task.sleep(nanoseconds: 80_000_000); let editor = try XCTUnwrap(f2Editor(hosted.controller.view)); XCTAssertTrue(editor.becomeFirstResponder())
        let cases: [(String, String, NSRange, String)] = [
            ("old", "new", NSRange(location: 3, length: 0), "old\nnewX"),
            ("旧😀", "中😀", NSRange(location: 3, length: 0), "旧😀\n中😀X"),
            ("old", "new", NSRange(location: 1, length: 1), "old\nnXw"),
            ("旧😀", "中😀文Z", NSRange(location: 1, length: 2), "旧😀\n中X文Z")
        ]
        for (index, item) in cases.enumerated() {
            owner.activate(scope: scope, conversationID: "A")
            editor.text = item.1; editor.selectedRange = item.2; editor.delegate?.textViewDidChange?(editor)
            let origin = try XCTUnwrap(owner.token); var sent = ComposerState.Draft(); sent.input = item.0
            if index.isMultiple(of: 2) { owner.activate(scope: scope, conversationID: "B"); owner.draft.input = "B draft"; try await Task.sleep(nanoseconds: 40_000_000) }
            owner.restoreFailedSend(sent, origin: origin)
            if index.isMultiple(of: 2) { XCTAssertEqual(owner.draft.input, "B draft"); XCTAssertEqual(editor.text, "B draft"); owner.activate(scope: scope, conversationID: "A") }
            try await Task.sleep(nanoseconds: 60_000_000)
            let expected = NSRange(location: (item.0 + "\n").utf16.count + item.2.location, length: item.2.length)
            XCTAssertEqual(editor.text, item.0 + "\n" + item.1); XCTAssertEqual(editor.selectedRange, expected); XCTAssertEqual(owner.draft.selection, expected)
            owner.restoreFailedSend(sent, origin: origin); try await Task.sleep(nanoseconds: 40_000_000); XCTAssertEqual(editor.selectedRange, expected)
            editor.insertText("X"); editor.delegate?.textViewDidChange?(editor)
            XCTAssertEqual(editor.text, item.3); XCTAssertEqual(owner.draft.input, item.3)
            let afterTyping = editor.selectedRange; owner.restoreFailedSend(sent, origin: origin)
            try await Task.sleep(nanoseconds: 40_000_000); XCTAssertEqual(editor.text, item.3); XCTAssertEqual(editor.selectedRange, afterTyping)
        }
    }
}
// WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110_END
