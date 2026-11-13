import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testPendingWorkspaceCopyDoesNotLookDisabledUnlessTenantIsReallyDisabled() {
        var pending = Enterprise(
            id: "tenant-pending",
            name: "Pending Enterprise",
            code: "WXT880001",
            role: "member",
            status: "pending",
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            joinStatus: "pending",
            applicationStatus: "pending",
            canSwitch: false,
            enterable: false,
            tenantStatus: "pending",
            memberStatus: "pending"
        )

        XCTAssertTrue(pending.isWorkspaceJoinPending)
        XCTAssertEqual(pending.workspaceDisabledDescription, "等待审批")

        pending.tenantStatus = "disabled"
        XCTAssertEqual(pending.workspaceDisabledDescription, "企业已停用")
    }

    func testNotJoinedWorkspaceCanStillApplyToJoin() {
        let item = Enterprise(
            id: "tenant-open",
            name: "Open Enterprise",
            code: "WXT900002",
            role: "member",
            status: "enabled",
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            joinStatus: "not_joined",
            canSwitch: false,
            enterable: false,
            tenantStatus: "enabled",
            disabledReason: "not_joined"
        )

        XCTAssertFalse(item.isWorkspaceJoined)
        XCTAssertFalse(item.isWorkspaceJoinPending)
        XCTAssertFalse(item.isWorkspaceJoinRejected)
        XCTAssertEqual(item.workspaceDisabledDescription, "")
    }

    func testMaskedPhoneDisplayTextSupportsTenDigitPhones() throws {
        XCTAssertEqual(maskedPhoneDisplayText("13800138000", emptyText: "未绑定"), "138****8000")
        XCTAssertEqual(maskedPhoneDisplayText("1900001002", emptyText: "未绑定"), "190*****002")
        XCTAssertEqual(maskedPhoneDisplayText("", emptyText: "未绑定"), "未绑定")
    }

    func testRemoteMyInviteCodeDecodesOrdinaryUserEmptyState() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": false,
          "status": "disabled",
          "reason_code": "member_invite_code_role_not_allowed"
        }
        """.utf8))

        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.reasonCode, "member_invite_code_role_not_allowed")
        XCTAssertNil(result.item)
        XCTAssertFalse(result.isUsableForRegistration)
        XCTAssertTrue(result.shouldHidePersonalInviteModule)
    }

    func testRemoteMyInviteCodeMarksFailedSyncUnavailableForRegistration() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "id": "invite-1",
            "tenant_id": "tenant-1",
            "im_uid": "uid-admin",
            "user_id": "WXT000001",
            "display_name": "Admin",
            "role": "admin",
            "member_invite_code": "WX7K9P2A",
            "status": "active",
            "sync_status": "failed",
            "sync_version": 2,
            "invite_count": 1,
            "joined_count": 0,
            "pending_count": 1
          }
        }
        """.utf8))

        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.memberInviteCode, "WX7K9P2A")
        XCTAssertTrue(result.isSyncFailed)
        XCTAssertFalse(result.isUsableForRegistration)
        XCTAssertFalse(result.shouldHidePersonalInviteModule)
    }

    func testMyInviteCodePresentationShowsAuthorityValueWhileKeepingFailedSyncNonCopyable() throws {
        let result = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "tenant_id": "tenant-test",
            "im_uid": "member-test",
            "member_invite_code": "YQMTEST1234",
            "status": "active",
            "sync_status": "failed"
          }
        }
        """.utf8))

        let presentation = MyInviteCodePresentation(
            inviteCode: result,
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(presentation.title, "YQMTEST1234")
        XCTAssertEqual(presentation.subtitle, "邀请码暂不可用于注册")
        XCTAssertNil(presentation.copyValue)
        XCTAssertFalse(presentation.isUsableForRegistration)
        XCTAssertTrue(presentation.isWarning)
        XCTAssertFalse(presentation.shouldShowStats)
        XCTAssertTrue(result.matchesAuthority(tenantID: "tenant-test", imUID: "member-test"))
        XCTAssertFalse(result.matchesAuthority(tenantID: "tenant-other", imUID: "member-test"))
    }

    func testMyInviteCodePresentationKeepsExistingCopyAndTruthfulEmptyErrorStates() throws {
        let usable = try JSONDecoder().decode(RemoteMyInviteCode.self, from: Data("""
        {
          "enabled": true,
          "item": {
            "member_invite_code": "YQMTEST5678",
            "status": "active",
            "sync_status": "synced"
          }
        }
        """.utf8))

        XCTAssertEqual(
            MyInviteCodePresentation(inviteCode: usable, isLoading: false, errorMessage: nil).copyValue,
            "YQMTEST5678"
        )
        XCTAssertEqual(
            MyInviteCodePresentation(inviteCode: nil, isLoading: false, errorMessage: nil).title,
            "暂不可用"
        )
        let forbidden = MyInviteCodePresentation(
            inviteCode: nil,
            isLoading: false,
            errorMessage: "当前账号无权限读取邀请码"
        )
        XCTAssertEqual(forbidden.title, "暂不可读取")
        XCTAssertEqual(forbidden.subtitle, "当前账号无权限读取邀请码")
        XCTAssertNil(forbidden.copyValue)
        XCTAssertFalse(usable.matchesAuthority(tenantID: "tenant-test", imUID: "member-test"))
    }

    @MainActor
    func testTenantLogoRelativeURLResolvesAgainstTenantBase() throws {
        let routeDefaults = UserDefaults(suiteName: "RemoteAPIModelsTests.routes.\(UUID().uuidString)")!
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )

        XCTAssertEqual(
            api.resolveTenantAssetURL("/api/tenant/avatar/file_logo_v2"),
            "https://tenant.example.test/api/tenant/avatar/file_logo_v2"
        )
    }

    @MainActor
    func testTenantLogoRelativeURLResolvesAgainstRuntimeTenantContext() throws {
        let api = IMAPIClient(tenantBase: URL(string: "http://127.0.0.1:5174")!)
        let context = IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: "tenant-a",
            imUID: "WXT000001",
            imToken: "im-token",
            tenantAPIBaseURL: "https://shanghu-a.wenxintong-test.com",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "ios-test-device"
        )

        XCTAssertEqual(
            api.resolveTenantAssetURL("/api/tenant/avatar/file_logo_v2", context: context),
            "https://shanghu-a.wenxintong-test.com/api/tenant/avatar/file_logo_v2"
        )
    }

    func testRemoteTenantIMSessionRefreshResultDecodesTopLevelC2Contract() throws {
        let result = try JSONDecoder().decode(RemoteTenantIMSessionRefreshResult.self, from: Data("""
        {
          "im_token": "new-im-token",
          "expires_at": 1782600000,
          "im_uid": "WXT00000002",
          "tenant_id": "tenant-1",
          "app_id": "jht-ios-main",
          "device_id": "ios-device-1",
          "token_type": "im"
        }
        """.utf8))

        XCTAssertEqual(result.imToken, "new-im-token")
        XCTAssertEqual(result.expiresAt, 1_782_600_000)
        XCTAssertEqual(result.imUID, "WXT00000002")
        XCTAssertEqual(result.tenantID, "tenant-1")
        XCTAssertEqual(result.appID, "jht-ios-main")
        XCTAssertEqual(result.deviceID, "ios-device-1")
        XCTAssertEqual(result.tokenType, "im")
    }

    func testRemoteTenantIMSessionRefreshResultDecodesSessionFallbackWithoutRefreshToken() throws {
        let result = try JSONDecoder().decode(RemoteTenantIMSessionRefreshResult.self, from: Data("""
        {
          "session": {
            "im_token": "session-im-token",
            "expires_at": "1782601234",
            "im_uid": "WXT00000003",
            "app_id": "jht-ios-main",
            "device_id": "ios-device-2"
          },
          "auth_session": {
            "token_type": "im",
            "tenant_id": "tenant-2",
            "app_id": "jht-ios-main",
            "device_id": "ios-device-2",
            "access_expires_at": 1782605678
          }
        }
        """.utf8))

        XCTAssertEqual(result.imToken, "session-im-token")
        XCTAssertEqual(result.expiresAt, 1_782_601_234)
        XCTAssertEqual(result.imUID, "WXT00000003")
        XCTAssertEqual(result.tenantID, "tenant-2")
        XCTAssertEqual(result.appID, "jht-ios-main")
        XCTAssertEqual(result.deviceID, "ios-device-2")
        XCTAssertEqual(result.tokenType, "im")
    }

    func testRemoteTenantProfileDecodesLogoRefreshFields() throws {
        let profile = try JSONDecoder().decode(RemoteTenantProfile.self, from: Data("""
        {
          "tenant_id": "t1",
          "tenant_code": "TEN1",
          "name": "Tenant Renamed",
          "status": "enabled",
          "logo_url": "/api/tenant/avatar/file_logo_v2",
          "logo_status": "ready",
          "logo_version": "logo-v2",
          "logo_updated_at": "2026-06-27T10:00:00Z",
          "logo_cache_key": "logo-v2",
          "logo_mime": "image/png",
          "logo_width": 256,
          "logo_height": 256
        }
        """.utf8))

        XCTAssertEqual(profile.name, "Tenant Renamed")
        XCTAssertEqual(profile.logoURL, "/api/tenant/avatar/file_logo_v2")
        XCTAssertEqual(profile.logoStatus, "ready")
        XCTAssertEqual(profile.logoVersion, "logo-v2")
        XCTAssertEqual(profile.logoCacheKey, "logo-v2")
        XCTAssertEqual(profile.logoWidth, 256)
        XCTAssertEqual(profile.logoHeight, 256)
    }

    func testRemoteTenantLogoObjectKeyOnlyFallsBackToDisplayableStablePath() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenant_code": "WXT123456",
          "name": "测试企业",
          "logo_object_key": "/api/tenant/avatar/file_logo_v3"
        }
        """.utf8))
        let unsafeObjectKey = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-2",
          "tenant_code": "WXT123457",
          "name": "旧对象企业",
          "logo_object_key": "tenant/logo/file_logo_v3.png"
        }
        """.utf8))

        XCTAssertEqual(tenant.logoURL, "/api/tenant/avatar/file_logo_v3")
        XCTAssertEqual(unsafeObjectKey.logoURL, "")
        XCTAssertEqual(unsafeObjectKey.logoCacheKey, "tenant/logo/file_logo_v3.png")
    }

    func testRemoteTenantSearchInviteEntryDecodesInviterDisplay() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenant_code": "WXT123456",
          "name": "测试企业",
          "status": "enabled",
          "entry_type": "member_invite_code",
          "scheme": "unified_v1",
          "canonical": "AB-I00A001",
          "inviter_nickname": "小王"
        }
        """.utf8))
        let enterprise = Enterprise(
            id: tenant.id,
            name: tenant.name,
            code: tenant.tenantCode,
            role: "",
            status: tenant.status,
            memberCount: 0,
            isDefault: false,
            accentHex: 0x5D6BFF,
            searchEntryType: tenant.entryType,
            searchInviterName: tenant.inviterNickname
        )

        XCTAssertEqual(tenant.entryType, "member_invite_code")
        XCTAssertEqual(tenant.entryScheme, "unified_v1")
        XCTAssertEqual(tenant.entryCanonical, "AB-I00A001")
        XCTAssertEqual(tenant.inviterNickname, "小王")
        XCTAssertEqual(enterprise.searchInviteDisplayLine, "邀请人：小王")
    }

    func testRemoteFileUploadConfigDecodesSplashConfiguration() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "max_mb": 10,
          "source": "tenant.files",
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-1",
          "splash_image_url": "/api/tenant/splash/assets/asset-1",
          "splash_version": "v3",
          "splash_width": "1170",
          "splash_height": 2532,
          "splash_mime_type": "image/png",
          "splash_size_bytes": "2048",
          "splash_etag": "etag-1",
          "splash_sha256": "sha-1",
          "splash_cache_key": "server-cache-v3",
          "splash_cache_strategy": "immutable",
          "splash_min_interval_sec": 3600,
          "splash_daily_cap": 2,
          "splash_min_show_ms": 800,
          "splash_max_show_ms": 3000,
          "splash_action_url": "https://example.test/splash"
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertTrue(splash.licenseEnabled)
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertTrue(splash.splashEnabled)
        XCTAssertEqual(splash.assetID, "asset-1")
        XCTAssertEqual(splash.imageURL, "/api/tenant/splash/assets/asset-1")
        XCTAssertEqual(splash.version, "v3")
        XCTAssertEqual(splash.width, 1170)
        XCTAssertEqual(splash.height, 2532)
        XCTAssertEqual(splash.mimeType, "image/png")
        XCTAssertEqual(splash.sizeBytes, 2048)
        XCTAssertEqual(splash.etag, "etag-1")
        XCTAssertEqual(splash.sha256, "sha-1")
        XCTAssertEqual(splash.cacheKey, "server-cache-v3")
        XCTAssertEqual(splash.cacheStrategy, "immutable")
        XCTAssertEqual(splash.minIntervalSec, 3600)
        XCTAssertEqual(splash.dailyCap, 2)
        XCTAssertEqual(splash.minShowMS, 800)
        XCTAssertEqual(splash.maxShowMS, 3000)
        XCTAssertEqual(splash.actionURL, "https://example.test/splash")
        XCTAssertEqual(splash.disabledReason, "")
    }

    func testRemoteFileUploadConfigDefinesExact500MiBBoundary() throws {
        let serverLimit = Int64(500 * 1024 * 1024)
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": \(serverLimit),
          "max_mb": 500,
          "source": "tenant.license"
        }
        """.utf8)).model

        XCTAssertEqual(config.maxBytes, serverLimit)
        XCTAssertEqual(config.source, "tenant.license")
        XCTAssertTrue(config.allowsUpload(sizeBytes: serverLimit))
        XCTAssertFalse(config.allowsUpload(sizeBytes: serverLimit + 1))
    }

    func testRemoteFileUploadConfigDecodesNestedDisabledSplashConfiguration() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "max_bytes": 1024,
          "features": {
            "splash_enabled": false,
            "splash_license_enabled": false,
            "splash_config_enabled": false
          },
          "splash": {
            "asset_id": "asset-disabled",
            "image_url": "/api/tenant/splash/assets/asset-disabled",
            "version": "v1"
          }
        }
        """.utf8))

        XCTAssertFalse(config.splashConfiguration.licenseEnabled)
        XCTAssertEqual(config.splashConfiguration.configEnabled, false)
        XCTAssertFalse(config.splashConfiguration.splashEnabled)
        XCTAssertEqual(config.splashConfiguration.assetID, "asset-disabled")
        XCTAssertEqual(config.splashConfiguration.disabledReason, "license_disabled")
    }

    func testRemoteFileUploadConfigDecodesStage4SplashAliasesAndIgnoresUploadLimits() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-stage4",
          "splash_image_url": "/api/tenant/splash/assets/asset-stage4",
          "splash_version": "v4",
          "splash_cache_key": "tenant-1/asset-stage4/v4",
          "splash_cache_strategy": "asset_version",
          "splash_upload_limits": {
            "max_bytes": 5242880,
            "min_width": 720,
            "min_height": 1280,
            "allowed_mime_types": ["image/jpeg", "image/png", "image/webp"]
          }
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertTrue(splash.licenseEnabled)
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertTrue(splash.splashEnabled)
        XCTAssertEqual(splash.assetID, "asset-stage4")
        XCTAssertEqual(splash.cacheKey, "tenant-1/asset-stage4/v4")
        XCTAssertEqual(splash.cacheStrategy, "asset_version")
        XCTAssertEqual(splash.disabledReason, "")

        let snapshot = splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-stage4",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(snapshot.cacheKey, SplashImageDiskCache.cacheKey(explicitKey: "tenant-1/asset-stage4/v4"))
    }

    func testRemoteFileUploadConfigDecodesNumericSplashVersionFromRealPayloadShape() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "custom_splash_enabled": true,
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_config_enabled": true,
          "splash_disabled_reason": "",
          "splash_asset_id": "da2476ad-38d6-48a6-964b-650672cc18e9",
          "splash_image_url": "/api/tenant/splash/assets/da2476ad-38d6-48a6-964b-650672cc18e9",
          "splash_version": 1,
          "splash_cache_key": "da2476ad-38d6-48a6-964b-650672cc18e9:1"
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertEqual(splash.configEnabled, true)
        XCTAssertEqual(splash.version, "1")
        XCTAssertEqual(splash.disabledReason, "")

        let snapshot = splash.makeSnapshot(
            tenantID: "tenant-real",
            resolvedImageURL: "http://127.0.0.1:8080/api/tenant/splash/assets/da2476ad-38d6-48a6-964b-650672cc18e9",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(snapshot.isConfigDisplayable)
        XCTAssertEqual(
            snapshot.cacheKey,
            SplashImageDiskCache.cacheKey(explicitKey: "da2476ad-38d6-48a6-964b-650672cc18e9:1")
        )
        XCTAssertNotEqual(snapshot.disabledReason, "missing_version")
    }

    func testRemoteFileUploadConfigDecodesStage4SplashDisabledReason() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "file_upload_max_bytes": 10485760,
          "splash_enabled": true,
          "splash_license_enabled": true,
          "splash_config_enabled": true,
          "splash_asset_id": "asset-deleted",
          "splash_image_url": "/api/tenant/splash/assets/asset-deleted",
          "splash_version": "v5",
          "splash_disabled_reason": "asset_deleted"
        }
        """.utf8))

        XCTAssertEqual(config.splashConfiguration.disabledReason, "asset_deleted")
        let snapshot = config.splashConfiguration.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-deleted"
        )
        XCTAssertFalse(snapshot.isConfigDisplayable)
        XCTAssertEqual(snapshot.disabledReason, "asset_deleted")
    }

    func testRemoteFileUploadConfigFailsClosedWhenSplashConfigFlagIsMissing() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_asset_id": "asset-missing-config",
          "splash_image_url": "/api/tenant/splash/assets/asset-missing-config",
          "splash_version": 1
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertNil(splash.configEnabled)
        XCTAssertEqual(splash.disabledReason, "splash_config_missing")
        XCTAssertFalse(splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-missing-config"
        ).isConfigDisplayable)
    }

    func testRemoteFileUploadConfigFailsClosedWhenSplashConfigIsDisabled() throws {
        let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data("""
        {
          "splash_license_enabled": true,
          "splash_enabled": true,
          "splash_config_enabled": false,
          "splash_asset_id": "asset-disabled-config",
          "splash_image_url": "/api/tenant/splash/assets/asset-disabled-config",
          "splash_version": 1
        }
        """.utf8))

        let splash = config.splashConfiguration
        XCTAssertEqual(splash.configEnabled, false)
        XCTAssertEqual(splash.disabledReason, "splash_config_disabled")
        XCTAssertFalse(splash.makeSnapshot(
            tenantID: "tenant-1",
            resolvedImageURL: "https://tenant.example.test/api/tenant/splash/assets/asset-disabled-config"
        ).isConfigDisplayable)
    }

    func testTenantModelsDecodeCamelCaseTenantNameAndCode() throws {
        let tenant = try JSONDecoder().decode(RemoteTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled"
        }
        """.utf8))
        let workspace = try JSONDecoder().decode(RemoteWorkspaceTenant.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled",
          "can_switch": true
        }
        """.utf8))
        let profile = try JSONDecoder().decode(RemoteTenantProfile.self, from: Data("""
        {
          "id": "tenant-1",
          "tenantCode": "WXT123456",
          "tenantName": "后台改名企业",
          "status": "enabled"
        }
        """.utf8))

        XCTAssertEqual(tenant.tenantCode, "WXT123456")
        XCTAssertEqual(tenant.name, "后台改名企业")
        XCTAssertEqual(workspace.tenantCode, "WXT123456")
        XCTAssertEqual(workspace.name, "后台改名企业")
        XCTAssertEqual(profile.tenantCode, "WXT123456")
        XCTAssertEqual(profile.name, "后台改名企业")
    }
}
