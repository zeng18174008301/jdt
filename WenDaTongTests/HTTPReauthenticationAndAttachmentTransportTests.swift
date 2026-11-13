import Foundation
import Combine
import IM4Core // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testSessionReauthenticationPlatformOnlyUsesFreshBearerAndRejectsWrongEntryIdentity() async throws {
        let login = try sessionReauthenticationLoginResult()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: login.data) as? [String: Any])
        var payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        payload.removeValue(forKey: "session")
        payload["default_workspace_id"] = "unrelated-default-tenant"
        envelope["data"] = payload
        let platformOnly = HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200
        )
        for mismatch in ["", "im_uid", "member.account_id", "member.tenant_id", "session.device_id"] {
            let wrongEntryIdentity = !mismatch.isEmpty
            let entry = try tenantPlatformEntrySuccess()
            var entryEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: entry.data) as? [String: Any])
            if wrongEntryIdentity {
                var entryData = try XCTUnwrap(entryEnvelope["data"] as? [String: Any])
                let fields = mismatch.split(separator: ".").map(String.init)
                if fields.count == 2 {
                    var nested = entryData[fields[0]] as? [String: Any] ?? [:]
                    nested[fields[1]] = "other-identity"
                    entryData[fields[0]] = nested
                } else {
                    entryData[mismatch] = "other-user"
                }
                entryEnvelope["data"] = entryData
            }
            let transport = FakeHTTPTransport(results: [
                activeAppPolicyResult(),
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                    isHTTPResponse: true, statusCode: 200
                ),
                platformOnly,
                try tenantEnterSuccess(entryTicket: "synthetic-reauth-entry", routes: runtimeRouteSnapshotForHTTPWiring()),
                HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: entryEnvelope), isHTTPResponse: true, statusCode: 200)
            ])
            let store = InMemoryProtectedSessionStore()
            let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
            // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
            let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
            let succeeded = await fixture.state.reauthenticateCurrentSession(
                identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
            )
            XCTAssertEqual(succeeded, !wrongEntryIdentity)
            let requests = transport.requests()
            let enter = try XCTUnwrap(requests.first { $0.url?.path == "/api/platform/me/tenants/tenant-1/enter" })
            XCTAssertEqual(enter.value(forHTTPHeaderField: "Authorization"), "Bearer reauth-platform-token")
            XCTAssertFalse(requests.contains { $0.url?.path.contains("unrelated-default-tenant") == true })
            let entryRequest = try XCTUnwrap(requests.first { $0.url?.path == "/api/tenant/auth/platform-entry" })
            XCTAssertEqual(try requestJSONObject(entryRequest)["entry_ticket"] as? String, "synthetic-reauth-entry")
            XCTAssertTrue(fixture.state.isAuthenticated)
            XCTAssertEqual(store.deleteAllCount, 0)
            if wrongEntryIdentity {
                XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
                XCTAssertEqual(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2"), originalSnapshot)
            } else {
                let saved = IMAPIContext.load(sessionStore: store)
                XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(saved))
                XCTAssertFalse(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
                XCTAssertEqual(saved.imToken, "im-token-new")
                XCTAssertEqual(saved.tenantID, fixture.original.tenantID)
                XCTAssertFalse(fixture.state.isSessionReauthenticationPresented)
            }
        }
    }

    func testSessionReauthenticationCandidateRejectsEveryScopeIdentityMismatch() throws {
        let original = makeRefreshableMessageSendContext()
        let validResult = try sessionReauthenticationLoginResult()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: validResult.data) as? [String: Any])
        let valid = try XCTUnwrap(envelope["data"] as? [String: Any])
        for (field, value) in [("requires_workspace_selection", true), ("can_direct_enter", false)] {
            var payload = valid
            payload[field] = value
            let data = try JSONDecoder().decode(RemoteTenantLoginData.self, from: JSONSerialization.data(withJSONObject: payload))
            let candidate = try AppState.sessionReauthenticationCandidate(data: data, original: original)
            XCTAssertFalse(candidate.hasIMSession, field)
            XCTAssertEqual(candidate.platformToken, "reauth-platform-token")
        }
        for (section, field, replacement) in [
            ("account", "id", "other-account"),
            ("tenant", "tenant_id", "other-tenant"),
            ("session", "device_id", "other-device"),
            ("session", "im_uid", "other-user"),
            ("session", "app_id", "other-app")
        ] {
            var payload = valid
            var identity = try XCTUnwrap(payload[section] as? [String: Any])
            identity[field] = replacement
            payload[section] = identity
            let data = try JSONDecoder().decode(RemoteTenantLoginData.self, from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertThrowsError(try AppState.sessionReauthenticationCandidate(data: data, original: original), "\(section).\(field)")
        }
    }

    func testAuthAccountIdentifierPolicyMatchesLoginBoundary() {
        XCTAssertFalse(isValidAuthAccountUsername("1234"))
        XCTAssertTrue(isValidAuthAccountUsername("12345"))
        XCTAssertTrue(isValidAuthAccountUsername("abcde12345"))
        XCTAssertFalse(isValidAuthAccountUsername("abcde123456"))
        XCTAssertFalse(isValidAuthAccountUsername("ab-cde"))
    }

    func testContactCardRequiresAuthoritativeMessageIDBeforeSuccessSurface() {
        XCTAssertFalse(AuthoritativeMessageSendPolicy.accepts(remoteMessageID: ""))
        XCTAssertFalse(AuthoritativeMessageSendPolicy.accepts(remoteMessageID: "   "))
        XCTAssertTrue(AuthoritativeMessageSendPolicy.accepts(remoteMessageID: "server-message-1"))
    }

    func testFriendRemarkInputPolicyMatchesServerUnicodeScalarLimit() throws {
        XCTAssertEqual(try FriendRemarkInputPolicy.normalize("  客户王总  "), "客户王总")
        XCTAssertEqual(try FriendRemarkInputPolicy.normalize("   "), "")
        XCTAssertEqual(try FriendRemarkInputPolicy.normalize(String(repeating: "中", count: 128)).unicodeScalars.count, 128)
        XCTAssertThrowsError(try FriendRemarkInputPolicy.normalize(String(repeating: "中", count: 129))) { error in
            XCTAssertEqual(error as? FriendRemarkValidationError, .tooLong(max: 128))
        }
        let familyEmoji = "👨‍👩‍👧‍👦"
        XCTAssertGreaterThan(familyEmoji.unicodeScalars.count, familyEmoji.count)
        XCTAssertEqual(FriendRemarkInputPolicy.unicodeCodePointCount(familyEmoji), familyEmoji.unicodeScalars.count)
    }

    struct UnsafeLocalizedDescriptionError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    #if canImport(WebRTC)
    func testVoiceAndVideoMediaClientsShareOneAvailableWebRTCRuntime() {
        let voiceClient = WebRTCVoiceMediaClient()
        let videoClient = WebRTCVideoMediaClient()

        XCTAssertTrue(voiceClient.isAvailable)
        XCTAssertTrue(videoClient.isAvailable)
    }
    #endif

    func testFakeHTTPTransportThrowsWhenResponseQueueIsEmpty() async throws {
        let transport = FakeHTTPTransport(results: [])
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://tenant.example.test/api/test")))

        do {
            _ = try await transport.data(for: request)
            XCTFail("Expected an exhausted fake response queue to throw")
        } catch {
            XCTAssertEqual(
                error as? FakeHTTPTransportError,
                .responseQueueExhausted(
                    method: "GET",
                    url: "https://tenant.example.test/api/test"
                )
            )
        }
        XCTAssertEqual(transport.requests().map(\.url), [request.url])
    }

    func testSignedContentTypeWinsForDataAndFileUploads() async throws {
        let bytes = Data("signed-body".utf8)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        for fromFile in [false, true] {
            for method in ["PUT", "POST"] {
                for headerName in ["Content-Type", "content-type", "cOnTeNt-TyPe"] {
                    let transport = FakeHTTPTransport(results: [], uploadResults: [
                        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
                    ])
                    let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
                    let signed = try makeUpload(
                        url: "https://object.example.test/exact?signature=fixture",
                        method: method,
                        headers: [headerName: "application/octet-stream", "X-Signed-Scope": "original"]
                    )
                    if fromFile {
                        try await client.uploadFileBinary(upload: signed, fileURL: fileURL, mimeType: "image/heic", sizeBytes: Int64(bytes.count))
                    } else {
                        try await client.uploadFileBinary(upload: signed, data: bytes, mimeType: "image/heic")
                    }
                    let request = try XCTUnwrap(fromFile ? transport.fileUploads().first?.request : transport.uploads().first?.request)
                    XCTAssertEqual(request.httpMethod, method)
                    XCTAssertEqual(request.url?.absoluteString, signed.url)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signed-Scope"), "original")
                    XCTAssertEqual(transport.fileUploads().count, fromFile ? 1 : 0)
                    XCTAssertEqual(transport.uploads().count, fromFile ? 0 : 1)
                    XCTAssertTrue(transport.requests().isEmpty)
                }
            }
        }
    }

    func testOSSUploadFailureKeepsOnlySafeCodeAndRequestIDForBothTransports() async throws {
        let bytes = Data([1, 2, 3])
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let requestID = "0123456789ABCDEF01234567"
        for fromFile in [false, true] {
            let transport = FakeHTTPTransport(results: [], uploadResults: [
                HTTPTransportResult(
                    data: Data("<Error><Code>SignatureDoesNotMatch</Code><Message>SENSITIVE_SENTINEL</Message><StringToSign>SENSITIVE_SENTINEL</StringToSign></Error>".utf8),
                    isHTTPResponse: true, statusCode: 403,
                    headers: ["X-OSS-Request-ID": requestID]
                )
            ])
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            let signed = try makeUpload(url: "https://object.example.test/SENSITIVE_SENTINEL?signature=SENSITIVE_SENTINEL", method: "PUT", headers: [:])
            let observation = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
            do {
                try await observation.captureUploadStep {
                    if fromFile {
                        try await client.uploadFileBinary(upload: signed, fileURL: fileURL, mimeType: "image/heic", sizeBytes: Int64(bytes.count))
                    } else {
                        try await client.uploadFileBinary(upload: signed, data: bytes, mimeType: "image/heic")
                    }
                }
                XCTFail("OSS denied the upload")
            } catch {
                let failure = try XCTUnwrap(observation.uploadFailure)
                XCTAssertEqual(failure, AttachmentUploadFailure(code: .http, httpStatus: 403, serverCode: "signaturedoesnotmatch", storageRequestID: requestID))
                XCTAssertFalse(failure.detail.contains("SENSITIVE_SENTINEL"))
                XCTAssertFalse(error.localizedDescription.contains("SENSITIVE_SENTINEL"))
                let restored = try JSONDecoder().decode(AttachmentUploadFailure.self, from: JSONEncoder().encode(failure))
                XCTAssertEqual(restored, failure)
            }
            XCTAssertEqual(transport.fileUploads().count + transport.uploads().count, 1)
            XCTAssertTrue(transport.requests().isEmpty)
        }
    }

    func testStorageUploadDiagnosticRejectsUnknownMetadataAndReadsLegacyCache() throws {
        for requestID in ["SENSITIVE_SENTINEL", "0123456789ABCDEF0123456G", "0123456789ABCDEF01234567\n", String(repeating: "A", count: 4096)] {
            let value = AttachmentUploadFailure(code: .http, httpStatus: 403, serverCode: "SENSITIVE_SENTINEL", storageRequestID: requestID)
            XCTAssertEqual(value.serverCode, "unrecognized_server_code")
            XCTAssertNil(value.storageRequestID)
            XCTAssertFalse(value.detail.contains("SENSITIVE_SENTINEL"))
        }
        let legacy = try JSONDecoder().decode(AttachmentUploadFailure.self, from: Data(#"{"code":"HTTP","httpStatus":403}"#.utf8))
        XCTAssertEqual(legacy, AttachmentUploadFailure(code: .http, httpStatus: 403))
        let unsafe = try JSONDecoder().decode(AttachmentUploadFailure.self, from: Data(#"{"code":"HTTP","httpStatus":403,"storageRequestID":"SENSITIVE_SENTINEL"}"#.utf8))
        XCTAssertNil(unsafe.storageRequestID)
    }

    func testFileBackedUploadUsesFileTransportWithExactMIMEAndContentLength() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-stream-upload-\(UUID().uuidString).gif")
        let exactLimit = Int64(500 * 1024 * 1024)
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("GIF89a".utf8)))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(exactLimit))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = FakeHTTPTransport(
            results: [],
            uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)]
        )
        let client = makeClient(transport: transport)

        try await client.uploadFileBinary(
            upload: try makeUpload(
                url: "https://object.example.test/animated.gif?signature=redacted",
                method: "PUT",
                headers: ["X-Signed-Scope": "object-put"]
            ),
            fileURL: fileURL,
            mimeType: "image/gif",
            sizeBytes: exactLimit,
            progress: { _ in }
        )

        let upload = try XCTUnwrap(transport.fileUploads().first)
        XCTAssertEqual(upload.fileURL, fileURL)
        XCTAssertEqual(upload.sizeBytes, exactLimit)
        XCTAssertTrue(upload.hasProgressDelegate)
        XCTAssertEqual(upload.request.httpMethod, "PUT")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "image/gif")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Length"), String(exactLimit))
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "X-Signed-Scope"), "object-put")
        XCTAssertEqual(upload.request.timeoutInterval, 60 * 60)
        XCTAssertTrue(transport.uploads().isEmpty)
    }

    func testFileBackedUploadRejectsSymbolicLinkBeforeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-stream-upload-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.bin")
        let linkURL = directory.appendingPathComponent("attachment.bin")
        let payload = Data("streamed".utf8)
        try payload.write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
        let transport = FakeHTTPTransport(
            results: [],
            uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)]
        )
        let client = makeClient(transport: transport)

        do {
            try await client.uploadFileBinary(
                upload: try makeUpload(
                    url: "https://object.example.test/attachment.bin?signature=redacted",
                    method: "PUT",
                    headers: [:]
                ),
                fileURL: linkURL,
                mimeType: "application/octet-stream",
                sizeBytes: Int64(payload.count)
            )
            XCTFail("Expected symbolic-link upload source to be rejected")
        } catch {
            XCTAssertTrue(transport.fileUploads().isEmpty)
        }
    }

    func testIMAPIClientAcceptsPlanNamedHTTPTransportAndWireCodecSeams() async throws {
        let transport: HTTPTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let wireCodec: any WireCodec = JSONWireCodec()
        let client = makeClient(transport: transport, wireCodec: wireCodec)

        let devices = try await client.listDevices(context: makeContext())

        XCTAssertTrue(devices.isEmpty)
    }

    func testMyLoginLogsUseCurrentUserSafeEndpointAndProjectSecurityCards() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"log-safe-1","device_type":"ios","result":"success","created_at":"2026-08-17T10:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let logs = try await client.listMyLoginLogs(context: makeContext())

        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.deviceType, "ios")
        XCTAssertEqual(logs.first?.result, "success")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/tenant/me/login-logs")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testAppStateRefreshLoginLogsReplacesHardcodedEmptyState() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"log-safe-1","device_type":"ios","result":"success","created_at":"2026-08-17T10:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        await state.refreshLoginLogs()

        XCTAssertEqual(state.loginLogs.count, 1)
        XCTAssertEqual(state.loginLogs.first?.device, "iOS")
        XCTAssertEqual(state.loginLogs.first?.result, "成功")
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/me/login-logs" }.count, 1)
    }

    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_BEGIN
    func testLoginLogRefreshPublishesOnlyToItsStoreAndResetsWithSessionData() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"scoped-log","device_type":"ios","result":"success","created_at":"2026-08-17T10:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        var publications = 0
        let appObservation = state.objectWillChange.sink { publications += 1 }
        var loading: [Bool] = []
        let loadObservation = state.loginLogStore.$isLoading.sink { loading.append($0) }

        await state.refreshLoginLogs()

        XCTAssertEqual(loading, [false, true, false])
        XCTAssertEqual(state.loginLogs.map(\.id), ["scoped-log"])
        XCTAssertEqual(publications, 0)
        appObservation.cancel()
        loadObservation.cancel()

        state.resetAuthenticatedRemoteData()
        XCTAssertTrue(state.loginLogStore.logs.isEmpty)
        XCTAssertFalse(state.loginLogStore.isLoading)
        XCTAssertFalse(state.loginLogStore.loadFailed)
    }
    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_END

    func testAppStateLoginLogFailureDoesNotFabricateAnEmptyAuditResult() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"login_logs_unavailable","message":"login logs are temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        await state.refreshLoginLogs()

        XCTAssertTrue(state.loginLogs.isEmpty)
        XCTAssertTrue(state.loginLogsLoadFailed)
        XCTAssertFalse(state.isLoginLogsLoading)
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/me/login-logs" }.count, 1)
    }

    func testPostLoginBackgroundUnauthorizedWithNonterminalRefreshPreservesColdLaunchSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = makeRefreshableMessageSendContext()
        context.save()
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"refresh_too_soon","message":"refresh_too_soon"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        await state.refreshLoginLogs()

        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path.contains("/session/refresh") == true }
                || !state.isAuthenticated
        }
        XCTAssertTrue(state.loginLogsLoadFailed)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertTrue(IMAPIContext.load().hasIMSession)
    }

    func testPlatformRefreshInvalidTokenFallsBackToTenantRefreshAndPreservesColdLaunchSession() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = makeRefreshableMessageSendContext()
        context.save()
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"expired_token","message":"expired_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"tenant-refreshed-im-token","expires_at":1800000000,"im_uid":"uid-1","tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","token_type":"im"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        await state.refreshLoginLogs()

        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/tenant/auth/session/refresh" }
                || !state.isAuthenticated
        }
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path.contains("/session/refresh") == true }.map(\.url?.path),
            [
                "/api/platform/tenants/tenant-1/session/refresh",
                "/api/tenant/auth/session/refresh"
            ]
        )
        XCTAssertTrue(state.loginLogsLoadFailed)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertEqual(IMAPIContext.load().imToken, "tenant-refreshed-im-token")
    }

    func testTenantRefreshExplicitSessionRevocationClearsOnlyTenantAfterPlatformFallback() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let context = makeRefreshableMessageSendContext()
        context.save()
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"expired_token","message":"expired_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"session_revoked","message":"session_revoked"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }

        await state.refreshLoginLogs()

        try await waitForCondition(iterations: 120) { !state.isAuthenticated }
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path.contains("/session/refresh") == true }.map(\.url?.path),
            [
                "/api/platform/tenants/tenant-1/session/refresh",
                "/api/tenant/auth/session/refresh"
            ]
        )
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertFalse(IMAPIContext.load().hasIMSession)
        XCTAssertEqual(IMAPIContext.load().platformToken, "platform-token")
        XCTAssertEqual(state.authScreen, .workspaceSelection)
    }

    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
    func testFavoriteAssetRefreshPublishesScopedSnapshotsWithoutAppStateRefresh() async {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            favoriteAssetsResult(items: [favoriteAssetJSON(messageID: "favorite", category: "image")]),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"favorite_assets_unavailable","message":"retry"}}"#.utf8),
                isHTTPResponse: true, statusCode: 503
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        var snapshots: [FileStore.FavoriteAssetsSnapshot] = []
        var globalUpdates = 0
        let storeObserver = state.fileStore.$favoriteAssetsSnapshot.sink { snapshots.append($0) }
        let globalObserver = state.objectWillChange.sink { globalUpdates += 1 }
        defer { storeObserver.cancel() }

        let first = await state.refreshFavoriteAssetsPage(silent: true, category: .image)
        XCTAssertTrue(first.didSucceed)
        let failure = await state.refreshFavoriteAssetsPage(silent: true, category: .image)
        XCTAssertFalse(failure.didSucceed)
        XCTAssertEqual(snapshots.map(\.isSyncing), [false, true, false, true, false])
        XCTAssertEqual(snapshots.last?.items.map(\.messageID), ["favorite"])
        XCTAssertEqual(snapshots.last?.errorMessage, "收藏资料加载失败，当前显示上次缓存")
        XCTAssertEqual(globalUpdates, 0)
        globalObserver.cancel()

        state.resetAuthenticatedRemoteData()
        XCTAssertEqual(snapshots.last, FileStore.FavoriteAssetsSnapshot())
        XCTAssertTrue(state.fileStore.favoriteAssetsCollection.activeScope.isEmpty)
    }
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END

    func testFavoriteAssetsCategoryFailureRestoresScopedCacheAndRetryDoesNotDuplicateItems() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            favoriteAssetsResult(items: [favoriteAssetJSON(messageID: "message-image", category: "image")]),
            favoriteAssetsResult(items: [favoriteAssetJSON(messageID: "message-pdf", category: "pdf")]),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"favorite_assets_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            favoriteAssetsResult(items: [
                favoriteAssetJSON(messageID: "message-image", category: "image", favoriteVersion: 2),
                favoriteAssetJSON(messageID: "message-image", category: "image", favoriteVersion: 2)
            ])
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

        let firstImage = await state.refreshFavoriteAssetsPage(silent: true, category: .image, limit: 15)
        XCTAssertTrue(firstImage.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-image"])

        let pdf = await state.refreshFavoriteAssetsPage(silent: true, category: .pdf, limit: 15)
        XCTAssertTrue(pdf.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-pdf"])

        let failedImage = await state.refreshFavoriteAssetsPage(silent: true, category: .image, limit: 15)
        XCTAssertFalse(failedImage.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-image"])
        XCTAssertEqual(state.favoriteAssetsSyncErrorMessage, "收藏资料加载失败，当前显示上次缓存")

        let retry = await state.refreshFavoriteAssetsPage(silent: true, category: .image, limit: 15)
        XCTAssertTrue(retry.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-image"])
        XCTAssertEqual(state.favoriteAssets.first?.favoriteVersion, 2)
        XCTAssertNil(state.favoriteAssetsSyncErrorMessage)
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/im/favorites/list" }.count, 4)
    }

    func testFavoriteAssetsPaginationFailureRetainsPageAndSameCursorRetryMergesWithoutDuplicates() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            favoriteAssetsResult(
                items: [favoriteAssetJSON(messageID: "message-1", category: "image")],
                nextCursor: "cursor-next",
                hasMore: true
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"favorite_assets_unavailable","message":"temporarily unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ),
            favoriteAssetsResult(items: [
                favoriteAssetJSON(messageID: "message-1", category: "image", favoriteVersion: 2),
                favoriteAssetJSON(messageID: "message-2", category: "image")
            ])
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let (decodeThreads, recordDecode) = AsyncStream<Bool>.makeStream()
        let trace: SDKHTTPTraceContext = (sourceCorrelation: 1, delivery: { _, _, _ in },
            decode: { _, _, main in recordDecode.yield(main) }, linkToPhysicalSource: { _ in })
        let first = await SDKHTTPTrace.$current.withValue(trace) {
            await state.refreshFavoriteAssetsPage(silent: true, category: .all, limit: 15)
        }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        XCTAssertTrue(first.didSucceed)
        XCTAssertEqual(first.nextCursor, "cursor-next")

        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let failed = await SDKHTTPTrace.$current.withValue(trace) {
            await state.refreshFavoriteAssetsPage(silent: true, category: .all, limit: 15,
                cursor: first.nextCursor, append: true)
        }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        XCTAssertFalse(failed.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-1"])

        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let retry = await SDKHTTPTrace.$current.withValue(trace) {
            await state.refreshFavoriteAssetsPage(silent: true, category: .all, limit: 15,
                cursor: first.nextCursor, append: true)
        }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        XCTAssertTrue(retry.didSucceed)
        XCTAssertEqual(state.favoriteAssets.map(\.messageID), ["message-1", "message-2"])
        XCTAssertEqual(state.favoriteAssets.first?.favoriteVersion, 2)

        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        recordDecode.finish()
        var mainThreadDecodes: [Bool] = []
        for await main in decodeThreads { mainThreadDecodes.append(main) }
        XCTAssertEqual(mainThreadDecodes, [false, false, false])

        let requests = transport.requests()
        XCTAssertEqual(requests.map(\.url?.path), Array(repeating: "/api/im/favorites/list", count: 3))
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST"])
        let requestBodies = try requests.map { request -> [String: Any] in
            let body = try XCTUnwrap(request.httpBody)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        XCTAssertEqual(requestBodies.map { $0["cursor"] as? String }, ["", "cursor-next", "cursor-next"])
        XCTAssertEqual(requestBodies.map { $0["category"] as? String }, ["all", "all", "all"])
        XCTAssertEqual(requestBodies.map { $0["limit"] as? Int }, [15, 15, 15])
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
    }

	func testRuntimeTenantRouteUsesURLProtocolAndFailsOverOnlyForQualifiedNetworkFailure() async throws {
		let suiteName = "RuntimeRouteURLProtocol.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		RuntimeRouteURLProtocol.reset()
		defer { RuntimeRouteURLProtocol.reset() }
		RuntimeRouteURLProtocol.install { request in
			switch request.url?.host {
			case "tenant-primary.example.com":
				throw URLError(.timedOut)
			case "tenant-backup.example.net":
				return (200, Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8))
			default:
				throw URLError(.badURL)
			}
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://seed-tenant.example.test")!,
			imBase: URL(string: "https://seed-im.example.test")!,
			httpTransport: URLSessionHTTPTransport(session: session),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)
		let routes = runtimeRouteSnapshotForHTTPWiring()
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)

		let startedAt = Date()
		let devices = try await client.listDevices(context: makeContext())
		let elapsed = Date().timeIntervalSince(startedAt)

		XCTAssertTrue(devices.isEmpty)
		XCTAssertGreaterThanOrEqual(elapsed, 4.9)
		XCTAssertLessThan(elapsed, 7)
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), [
			"tenant-primary.example.com", "tenant-backup.example.net"
		])
	}

	func testUserProfilesReadOnlyPostWaitsForSharedThresholdThenReplaysToBackup() async throws {
		let suiteName = "RuntimeUserProfilesReplay.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		RuntimeRouteURLProtocol.reset()
		defer { RuntimeRouteURLProtocol.reset() }
		RuntimeRouteURLProtocol.install { request in
			switch request.url?.host {
			case "tenant-primary.example.com":
				throw URLError(.timedOut)
			case "tenant-backup.example.net":
				return (
					200,
					Data(#"{"ok":true,"data":{"items":[],"missing_uids":["uid-1"],"max_uids":100}}"#.utf8)
				)
			default:
				throw URLError(.badURL)
			}
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let client = IMAPIClient(
			platformBase: URL(string: "https://platform.example.test")!,
			tenantBase: URL(string: "https://seed-tenant.example.test")!,
			imBase: URL(string: "https://seed-im.example.test")!,
			httpTransport: URLSessionHTTPTransport(session: session),
			runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
		)
		XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)

		let startedAt = Date()
		let response = try await client.userProfiles(context: makeContext(), exactUIDs: ["uid-1"])
		let elapsed = Date().timeIntervalSince(startedAt)

		XCTAssertEqual(response.missingUIDs, ["uid-1"])
		XCTAssertGreaterThanOrEqual(elapsed, 4.9)
		XCTAssertLessThan(elapsed, 7)
		XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), [
			"tenant-primary.example.com", "tenant-backup.example.net",
		])
		XCTAssertEqual(RuntimeRouteURLProtocol.requestTimeouts().count, 2)
		for timeout in RuntimeRouteURLProtocol.requestTimeouts() {
			XCTAssertEqual(timeout, 1.8, accuracy: 0.01)
		}
	}
}
