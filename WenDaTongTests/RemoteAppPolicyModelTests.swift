import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteAppCurrentPolicyDecodesSnakeAndCamelAliases() throws {
        let snake = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jht-ios-main",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": false,
          "allow_default_tenant_join": true,
          "require_real_name": true,
          "require_phone_verification": false,
          "department_enabled": true,
          "support_contact_email": "support@example.com",
          "support_contact_configured": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let camel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "appId": "jht-ios-main",
          "platform": "ios",
          "status": "disabled",
          "allowWorkspaceSwitch": true,
          "allowDefaultTenantJoin": false,
          "requireRealName": false,
          "requirePhoneVerification": true,
          "organization": {
            "departmentEnabled": true
          },
          "supportContactEmail": "",
          "supportContactConfigured": false,
          "cacheTTLSeconds": 30
        }
        """.utf8))

        XCTAssertEqual(snake.appID, "jht-ios-main")
        XCTAssertEqual(snake.platform, "ios")
        XCTAssertFalse(snake.allowWorkspaceSwitch)
        XCTAssertTrue(snake.allowDefaultTenantJoin)
        XCTAssertTrue(snake.requireRealName)
        XCTAssertFalse(snake.requirePhoneVerification)
        XCTAssertTrue(snake.departmentEnabled)
        XCTAssertEqual(snake.supportContactEmail, "support@example.com")
        XCTAssertTrue(snake.supportContactConfigured)
        XCTAssertFalse(snake.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(snake.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(snake.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(snake.cacheTTLSeconds, 60)
        XCTAssertTrue(snake.isUsable)

        XCTAssertEqual(camel.appID, "jht-ios-main")
        XCTAssertEqual(camel.platform, "ios")
        XCTAssertTrue(camel.allowWorkspaceSwitch)
        XCTAssertFalse(camel.allowDefaultTenantJoin)
        XCTAssertFalse(camel.requireRealName)
        XCTAssertTrue(camel.requirePhoneVerification)
        XCTAssertTrue(camel.departmentEnabled)
        XCTAssertEqual(camel.supportContactEmail, "")
        XCTAssertFalse(camel.supportContactConfigured)
        XCTAssertFalse(camel.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(camel.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(camel.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(camel.cacheTTLSeconds, 30)
        XCTAssertFalse(camel.isUsable)
    }

    func testPhoneAuthPolicyDefaultsToEnabledAndDecodesExplicitDisable() throws {
        let missing = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "allow_workspace_switch":true,
          "allow_default_tenant_join":true
        }
        """#.utf8))
        let disabled = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "allow_workspace_switch":true,
          "allow_default_tenant_join":true,
          "phone_auth_enabled":false
        }
        """#.utf8))

        XCTAssertTrue(missing.phoneAuthEnabled)
        XCTAssertFalse(disabled.phoneAuthEnabled)
        XCTAssertTrue(disabled.settingPhoneAuthEnabled(true).phoneAuthEnabled)
    }

    func testRemoteAppCurrentPolicyDecodesRegistrationAndEnterpriseFirstAliasesAcrossSupportedNesting() throws {
        let snake = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "policy": {
            "allow_default_tenant_join": false,
            "auth_policy": { "prefer_enterprise_code": true },
            "register_policy": { "registration_enabled": false }
          },
          "preferred_enterprise_code":"wxt123456"
        }
        """#.utf8))
        let camel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {
          "appId":"jht-ios-main",
          "status":"active",
          "appPolicy": {
            "allowDefaultTenantJoin": true,
            "loginPolicy": { "enterpriseCodeFirst": true },
            "registerPolicy": { "openRegistration": true }
          },
          "preferred_enterprise_code":"WXT654321"
        }
        """#.utf8))

        XCTAssertFalse(snake.allowDefaultTenantJoin)
        XCTAssertFalse(snake.registrationEnabled)
        XCTAssertTrue(snake.enterpriseCodeFirst)
        XCTAssertEqual(snake.preferredEnterpriseCode, "WXT123456")
        XCTAssertTrue(camel.allowDefaultTenantJoin)
        XCTAssertTrue(camel.registrationEnabled)
        XCTAssertTrue(camel.enterpriseCodeFirst)
        XCTAssertEqual(camel.preferredEnterpriseCode, "WXT654321")
    }

    func testRemoteAppCurrentPolicyLegacyDefaultsRegistrationEnabledAndEnterpriseFirstDisabled() throws {
        let policy = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
        {"app_id":"jht-ios-main","status":"active"}
        """#.utf8))

        XCTAssertTrue(policy.allowDefaultTenantJoin)
        XCTAssertTrue(policy.registrationEnabled)
        XCTAssertFalse(policy.enterpriseCodeFirst)
        XCTAssertEqual(policy.preferredEnterpriseCode, "")
    }

    func testAppBootstrapDecodesNestedPolicyAliasesAndFailsClosedForInvalidConfiguredFlags() throws {
        let enabled = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "appPolicy": {
            "registerPolicy": { "registrationOpen": "enabled" },
            "authPolicy": { "preferEnterpriseCode": 1 }
          },
          "preferredEnterpriseCode":"WXT000321"
        }
        """#.utf8))
        let invalid = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jht-ios-main",
          "status":"active",
          "registration_enabled":"not-a-boolean",
          "enterprise_code_first":"not-a-boolean"
        }
        """#.utf8))

        XCTAssertTrue(enabled.registrationEnabled)
        XCTAssertTrue(enabled.enterpriseCodeFirst)
        XCTAssertEqual(enabled.preferredEnterpriseCode, "WXT000321")
        XCTAssertFalse(invalid.registrationEnabled)
        XCTAssertFalse(invalid.enterpriseCodeFirst)
    }

    func testPreferredEnterpriseCodeRequiresAuthoritativeCanonicalAppAndSupportedFormat() throws {
        func decode(appID: String, code: String, enabled: Bool = true) throws -> RemoteAppCurrentPolicy {
            try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data(#"""
            {"app_id":"\#(appID)","status":"active","enterprise_code_first":\#(enabled),"preferred_enterprise_code":"\#(code)"}
            """#.utf8))
        }

        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "wxt000123").preferredEnterpriseCode, "WXT000123")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: " ab001234 ").preferredEnterpriseCode, "AB001234")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "AB-I00A001").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "other-ios", code: "WXT000123").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "WXT12345").preferredEnterpriseCode, "")
        XCTAssertEqual(try decode(appID: "jht-ios-main", code: "WXT000123", enabled: false).preferredEnterpriseCode, "")
    }

    func testAppBootstrapPreservesPhoneAuthFlagFromAllFrozenLocations() throws {
        let missing = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active"
        }
        """#.utf8))
        let topLevel = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(#"""
        {
          "app_id":"jianhuitong-ios",
          "status":"active",
          "phone_auth_enabled":false
        }
        """#.utf8))

        XCTAssertTrue(missing.phoneAuthEnabled)
        XCTAssertFalse(topLevel.phoneAuthEnabled)

        for containerKey in ["auth_policy", "register_policy", "login_policy", "tenant_pool"] {
            let json = """
            {
              "app_id":"jianhuitong-ios",
              "status":"active",
              "\(containerKey)":{"phone_auth_enabled":false}
            }
            """
            let nested = try JSONDecoder().decode(RemoteAppBootstrap.self, from: Data(json.utf8))
            XCTAssertFalse(nested.phoneAuthEnabled, "expected \(containerKey) to preserve phone_auth_enabled")
        }
    }

    func testRemoteAppCurrentPolicyDecodesAccessDiagnosticsPolicyFlags() throws {
        let topLevel = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "access_diagnostics_overlay_enabled": true,
          "access_diagnostics_copy_enabled": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let nested = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "debug_features": {
            "access_diagnostics_overlay_enabled": "true",
            "access_diagnostics_copy_enabled": 1
          },
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let missing = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "allow_workspace_switch": true,
          "allow_default_tenant_join": true,
          "cache_ttl_seconds": 60
        }
        """.utf8))
        let explicitlyDisabled = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {
          "app_id": "jianhuitong-ios",
          "platform": "ios",
          "status": "active",
          "access_diagnostics_overlay_enabled": false,
          "cache_ttl_seconds": 60
        }
        """.utf8))

        XCTAssertTrue(topLevel.accessDiagnosticsOverlayEnabled)
        XCTAssertTrue(topLevel.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(topLevel.accessDiagnosticsOverlayConfiguration, .enabled)
        XCTAssertTrue(nested.accessDiagnosticsOverlayEnabled)
        XCTAssertTrue(nested.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(nested.accessDiagnosticsOverlayConfiguration, .enabled)
        XCTAssertFalse(missing.accessDiagnosticsOverlayEnabled)
        XCTAssertFalse(missing.accessDiagnosticsCopyEnabled)
        XCTAssertEqual(missing.accessDiagnosticsOverlayConfiguration, .unavailable)
        XCTAssertEqual(missing.accessDiagnosticsOverlayConfiguration.displayText, "配置未获取")
        XCTAssertFalse(explicitlyDisabled.accessDiagnosticsOverlayEnabled)
        XCTAssertEqual(explicitlyDisabled.accessDiagnosticsOverlayConfiguration, .disabled)
        XCTAssertEqual(explicitlyDisabled.accessDiagnosticsOverlayConfiguration.displayText, "已关闭")
    }

    func testRemoteOrganizationTreeAndMembersDecodeDepartmentFields() throws {
        let tree = try JSONDecoder().decode(RemoteOrganizationTree.self, from: Data("""
        {
          "department_enabled": true,
          "can_manage": true,
          "can_manage_department": true,
          "root": {
            "department_id": "company",
            "name": "公司",
            "is_virtual": true,
            "member_count": 2,
            "children": [
              {
                "department_id": "dep-risk",
                "parent_department_id": "company",
                "name": "风控部",
                "department_path_names": ["公司", "风控部"],
                "member_count": 3,
                "children": []
              }
            ]
          },
          "items": []
        }
        """.utf8))

        XCTAssertTrue(tree.departmentEnabled)
        XCTAssertTrue(tree.canManage)
        XCTAssertTrue(tree.canManageDepartment)
        XCTAssertEqual(tree.root?.departmentID, "company")
        XCTAssertEqual(tree.root?.name, "公司")
        XCTAssertEqual(tree.root?.isVirtual, true)
        XCTAssertEqual(tree.root?.children.first?.departmentID, "dep-risk")
        XCTAssertEqual(tree.root?.children.first?.departmentPathNames, ["公司", "风控部"])

        let members = try JSONDecoder().decode(RemoteOrganizationMemberList.self, from: Data("""
        {
          "department_enabled": true,
          "canManage": true,
          "canManageDepartment": true,
          "department_id": "dep-risk",
          "items": [
            {
              "im_uid": "im-1",
              "user_id": "u-1",
              "nickname": "Alice",
              "department_id": "dep-risk",
              "department_name": "风控部",
              "department_path_names": ["公司", "风控部"],
              "position_name": "审核员",
              "is_primary": "true",
              "sort_order": "7"
            }
          ]
        }
        """.utf8))

        let member = try XCTUnwrap(members.items.first)
        XCTAssertTrue(members.departmentEnabled)
        XCTAssertTrue(members.canManage)
        XCTAssertTrue(members.canManageDepartment)
        XCTAssertEqual(members.departmentID, "dep-risk")
        XCTAssertEqual(member.id, "im-1")
        XCTAssertEqual(member.departmentName, "风控部")
        XCTAssertEqual(member.departmentPathNames, ["公司", "风控部"])
        XCTAssertTrue(member.isPrimary)
        XCTAssertEqual(member.sortOrder, 7)
    }

    func testRemoteTenantContextDecodesDepartmentPolicyAndUserDepartment() throws {
        let context = try JSONDecoder().decode(RemoteTenantContext.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "im_uid": "im-1",
          "app_id": "jht-ios-main",
          "device_id": "ios-1",
          "tenant": {
            "tenant_id": "tenant-1",
            "tenant_code": "WXT000001",
            "name": "测试企业",
            "status": "active"
          },
          "tenant_policy": {
            "organization": {
              "department_enabled": true
            }
          },
          "user": {
            "im_uid": "im-1",
            "user_id": "u-1",
            "nickname": "Alice",
            "department_name": "风控部",
            "department_path_names": ["公司", "风控部"]
          }
        }
        """.utf8))

        XCTAssertEqual(context.departmentEnabled, true)
        XCTAssertEqual(context.user?.departmentName, "风控部")
        XCTAssertEqual(context.user?.departmentPathNames, ["公司", "风控部"])
        XCTAssertEqual(context.clientPolicy?.allowMemberGroupCreation, false)
        XCTAssertEqual(context.clientPolicy?.clientFriendRequests, false)
        XCTAssertEqual(context.clientPolicy?.showGroupMemberCount, false)
        XCTAssertEqual(context.clientPolicy?.showOnlineStatus, true)
        XCTAssertEqual(context.clientPolicy?.showLastLoginTime, false)
        XCTAssertEqual(context.clientPolicy?.loginRequireBoundDevice, false)
        XCTAssertEqual(context.clientPolicy?.messageExportEnabled, false)
    }

    func testForcedAuthPolicyRequiresRealNameWhenUserIsUnverified() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testForcedAuthPolicyRequiresPhoneWhenUserPhoneIsUnverified() {
        let policy = makeForcedAuthPolicy(requireRealName: false, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: true, realNameStatus: "verified", phoneVerified: false)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .phone)
    }

    func testForcedAuthPolicyPrioritizesPhoneWhenBothAreMissing() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: false)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .phone)
    }

    func testForcedAuthPolicyFallsThroughToRealNameAfterPhoneIsComplete() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: true)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testForcedAuthPolicyDoesNotPromptWhenNoRequirementIsEnabled() {
        let policy = makeForcedAuthPolicy(requireRealName: false, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "unsubmitted", phoneVerified: false)

        XCTAssertNil(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user))
    }

    func testForcedAuthPolicyTreatsPendingRealNameAsIncomplete() {
        let policy = makeForcedAuthPolicy(requireRealName: true, requirePhoneVerification: false)
        let user = makeForcedAuthUser(realNameVerified: false, realNameStatus: "pending", phoneVerified: true)

        XCTAssertEqual(AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user), .realName)
    }

    func testGroupNicknameInputPolicyNormalizesNFCAndUnicodeWhitespace() throws {
        let normalized = try GroupNicknameInputPolicy.normalize("\u{3000}Cafe\u{301}\u{00A0}")

        XCTAssertEqual(normalized, "Café")
        XCTAssertEqual(normalized.unicodeScalars.count, 4)
    }

    func testGroupNicknameInputPolicyAllowsClearAndRejectsControlsAndMoreThan64Scalars() throws {
        XCTAssertEqual(try GroupNicknameInputPolicy.normalize(" \n "), "")
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize("昵称\n第二行")) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize("昵称\u{202E}覆盖")) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try GroupNicknameInputPolicy.normalize(String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(error as? GroupNicknameInputError, .tooLong)
        }
    }

    private func makeForcedAuthPolicy(requireRealName: Bool, requirePhoneVerification: Bool) -> RemoteAppCurrentPolicy {
        RemoteAppCurrentPolicy(
            appID: "jht-ios-main",
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            cacheTTLSeconds: 60
        )
    }

    func makeForcedAuthUser(
        id: String = "u1",
        userID: String = "",
        realNameVerified: Bool,
        realNameStatus: String,
        phoneVerified: Bool
    ) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            name: "测试用户",
            title: "",
            department: "",
            phone: phoneVerified ? "138****0000" : "",
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
    }
}
