@testable import IM4Features
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
@testable import IM4Data
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END
import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testHTTPTransportPreservesRateLimitRetryAfterHeader() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"rate_limited","message":"too many"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 429,
                headers: ["Retry-After": "12", "X-Request-ID": "req-1"]
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected rate limit error")
        } catch IMAPIError.rateLimited(let code, let message, let retryAfterSeconds, _) {
            XCTAssertEqual(code, "rate_limited")
            XCTAssertEqual(message, "too many")
            XCTAssertEqual(retryAfterSeconds, 12)
        }
    }

    func testDeviceDisabledForbiddenPostsRevocationNotification() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"forbidden","message":"forbidden: device disabled"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let client = makeClient(transport: transport)
        let revoked = expectation(forNotification: .imCurrentDeviceRevoked, object: nil)

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected device revocation error")
        } catch IMAPIError.unauthorized(let message) {
            XCTAssertEqual(message, DeviceRevocationDetector.logoutMessage)
        }
        await fulfillment(of: [revoked], timeout: 1)
    }

    func testDeviceRevokedForbiddenPostsRevocationNotification() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"device_revoked","message":"current device session revoked"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let client = makeClient(transport: transport)
        let revoked = expectation(forNotification: .imCurrentDeviceRevoked, object: nil)

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected device revocation error")
        } catch IMAPIError.unauthorized(let message) {
            XCTAssertEqual(message, DeviceRevocationDetector.logoutMessage)
        }
        await fulfillment(of: [revoked], timeout: 1)
    }

    func testHTTPTransportKeepsIdempotentGETDedupeInClient() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 50_000_000
        )
        let client = makeClient(transport: transport)
        let context = makeContext()

        async let first: [RemoteUserDevice] = client.listDevices(context: context)
        async let second: [RemoteUserDevice] = client.listDevices(context: context)
        _ = try await (first, second)

        XCTAssertEqual(transport.requests().count, 1)
    }

    func testHTTPInFlightRequestStoreReusesTaskUntilCreatorFinishes() async throws {
        let store = HTTPInFlightRequestStore<Int>()
        var createdTaskCount = 0

        let first = store.task(for: "GET:/api/tenant/devices") {
            createdTaskCount += 1
            return Task<Int, Error> { 41 }
        }
        let second = store.task(for: "GET:/api/tenant/devices") {
            createdTaskCount += 1
            return Task<Int, Error> { 42 }
        }

        XCTAssertEqual(createdTaskCount, 1)
        XCTAssertEqual(store.registeredTaskCount, 1)
        let firstValue = try await first.task.value
        let secondValue = try await second.task.value
        XCTAssertEqual(firstValue, 41)
        XCTAssertEqual(secondValue, 41)

        store.finish(second)
        XCTAssertEqual(store.registeredTaskCount, 1)

        store.finish(first)
        XCTAssertEqual(store.registeredTaskCount, 0)
    }

    func testHTTPInFlightRequestStoreDoesNotRegisterEmptyKeys() async throws {
        let store = HTTPInFlightRequestStore<Int>()
        var createdTaskCount = 0

        let nilKey = store.task(for: nil) {
            createdTaskCount += 1
            return Task<Int, Error> { 1 }
        }
        let emptyKey = store.task(for: "") {
            createdTaskCount += 1
            return Task<Int, Error> { 2 }
        }

        XCTAssertEqual(createdTaskCount, 2)
        XCTAssertEqual(store.registeredTaskCount, 0)
        let nilKeyValue = try await nilKey.task.value
        let emptyKeyValue = try await emptyKey.task.value
        XCTAssertEqual(nilKeyValue, 1)
        XCTAssertEqual(emptyKeyValue, 2)

        store.finish(nilKey)
        store.finish(emptyKey)
        XCTAssertEqual(store.registeredTaskCount, 0)
    }

    // WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_BEGIN
    func testHTTPInFlightRequestStoreLateCreatorCannotRemoveReplacementAfterReset() async throws {
        captureA43RuntimeLoadedImages()
        let store = HTTPInFlightRequestStore<Int>()
        let key = "GET:/api/tenant/devices"
        let oldStarted = expectation(description: "old shared task started")
        let (oldGate, releaseOld) = AsyncStream<Void>.makeStream()
        let (replacementGate, releaseReplacement) = AsyncStream<Void>.makeStream()
        defer {
            releaseOld.finish()
            releaseReplacement.finish()
        }

        let old = store.task(for: key) {
            Task {
                oldStarted.fulfill()
                for await _ in oldGate { break }
                try Task.checkCancellation()
                return 1
            }
        }
        let oldBorrower = store.task(for: key) { Task { -1 } }
        XCTAssertEqual(oldBorrower.task, old.task)
        await fulfillment(of: [oldStarted], timeout: 1)

        store.reset()
        XCTAssertEqual(store.registeredTaskCount, 0)
        let replacement = store.task(for: key) {
            Task {
                for await _ in replacementGate { break }
                return 2
            }
        }
        XCTAssertNotEqual(old.task, replacement.task)
        releaseOld.finish()
        let oldValue = try await old.task.value
        let oldBorrowedValue = try await oldBorrower.task.value
        XCTAssertEqual(oldValue, 1)
        XCTAssertEqual(oldBorrowedValue, 1)
        store.finish(old)
        store.finish(oldBorrower)
        XCTAssertEqual(store.registeredTaskCount, 1)

        let borrower = store.task(for: key) { Task { -2 } }
        XCTAssertEqual(borrower.task, replacement.task)
        releaseReplacement.finish()
        let borrowedValue = try await borrower.task.value
        XCTAssertEqual(borrowedValue, 2)
        store.finish(borrower)
        XCTAssertEqual(store.registeredTaskCount, 1)
        store.finish(replacement)
        XCTAssertEqual(store.registeredTaskCount, 0)
    }
    // WDT_IOS1_HTTP_RESET_LATE_CLAIM_20261111_END

    func testHTTPTransportDoesNotDedupeClearOnReadGETPaths() {
        let base = URL(string: "https://im.example.test")!
        let callEventsKey = IMAPIClient.idempotentGETRequestKey(
            base: base,
            path: "/api/rtc/calls/events",
            method: "GET",
            bearer: "im-token",
            body: nil
        )
        let deviceKey = IMAPIClient.idempotentGETRequestKey(
            base: base,
            path: "/api/tenant/devices",
            method: "GET",
            bearer: "im-token",
            body: nil
        )

        XCTAssertNil(callEventsKey)
        XCTAssertNotNil(deviceKey)
    }

    func testIMAPIClientReportMessageUsesTenantEndpointIMBearerAndBodyContract() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"report-1"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.reportMessage(
            context: makeContext(),
            messageID: " msg-1 ",
            channelID: " group-1 ",
            channelType: " group ",
            reason: MessageReportCategory.spam.rawValue,
            description: "  对方反复发外链  "
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/message-reports")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        XCTAssertEqual(body["message_id"], "msg-1")
        XCTAssertEqual(body["channel_id"], "group-1")
        XCTAssertEqual(body["channel_type"], "group")
        XCTAssertEqual(body["reason"], "广告引流")
        XCTAssertEqual(body["description"], "对方反复发外链")
    }

    func testIMAPIClientMessageReportLookupUsesTenantEndpointAndIMBearer() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"reported":true,"report":{"id":"report-1","message_id":"msg-1","reason":"辱骂骚扰","description":"反复辱骂","already_reported":true,"read_only":true}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.lookupMessageReport(context: makeContext(), messageID: " msg-1 ")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/message-reports/lookup?message_id=msg-1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertTrue(result.reported)
        XCTAssertEqual(result.report?.reason, "辱骂骚扰")
        XCTAssertEqual(result.report?.description, "反复辱骂")
        XCTAssertEqual(result.report?.alreadyReported, true)
        XCTAssertEqual(result.report?.readOnly, true)
    }

    func testIMAPIClientAccountCancellationUsesTenantEndpointIMBearerAndConfirmedBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"cancelled":true,"profile":{"nickname":"用户已注销","avatar":"/avatars/user-cancelled-gray.svg","username":"","phone":"","status":"cancelled"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.cancelAccount(context: makeContext(), reason: "  不再使用  ")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/me/account-cancellation")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer platform-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["confirmed"] as? Bool, true)
        XCTAssertEqual(body["reason"] as? String, "不再使用")
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.profile?.nickname, "用户已注销")
        XCTAssertEqual(result.profile?.avatar, cancelledUserAvatarPath)
    }

    func testIMAPIClientReportMessageFailureOnlyPostsReportRequest() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"validation_failed","message":"举报理由不能为空"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 422
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.reportMessage(
                context: makeContext(),
                messageID: "msg-1",
                channelID: "group-1",
                channelType: "group",
                reason: MessageReportCategory.abuse.rawValue,
                description: "辱骂骚扰"
            )
            XCTFail("Expected report request to fail")
        } catch {
            // Failure must not trigger a conversation refresh or reload side request.
        }

        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/tenant/message-reports")
    }

    func testFriendRemarkPatchUsesCanonicalUIDAsStrictSinglePathSegment() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"friend/with+space ?#","user_id":"WXT000001","remark":"客户王总"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.updateFriendRemark(
            context: makeContext(),
            canonicalFriendUID: "friend/with+space ?#",
            remark: "  客户王总  "
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://tenant.example.test/api/tenant/friends/friend%2Fwith%2Bspace%20%3F%23"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["remark": "客户王总"])
    }

    func testFriendProfileReadbackUsesSameStrictPathSegmentAndReloadPolicy() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_uid":"friend/with+space ?#","user_id":"WXT000001","remark":"客户王总"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let profile = try await client.friendProfile(
            context: makeContext(),
            canonicalFriendUID: "friend/with+space ?#"
        )

        XCTAssertEqual(profile.imUID, "friend/with+space ?#")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://tenant.example.test/api/tenant/friends/friend%2Fwith%2Bspace%20%3F%23"
        )
    }

    func testHTTPClientUsesInjectedWireCodecForGETResponseDecodeWithoutEncodingBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("codec-response".utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let wireCodec = RecordingHTTPWireCodec()
        let client = makeClient(transport: transport, wireCodec: wireCodec)

        let devices = try await client.listDevices(context: makeContext())

        XCTAssertTrue(devices.isEmpty)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(wireCodec.encodedObjectCount(), 0)
        // WDT_CHAT_RESOURCE_PERF_20261023: unrelated endpoints retain their existing executor.
        XCTAssertEqual(wireCodec.decodedOnMainThread(), [true, true, true])
        XCTAssertEqual(
            wireCodec.decodedTypeNames(),
            [
                "APIErrorEnvelope",
                "APILoginSecurityEnvelope",
                "APIEnvelope<RemoteList<RemoteUserDevice>>"
            ]
        )
        XCTAssertEqual(
            wireCodec.decodedInputTexts(),
            [
                "codec-response",
                "codec-response",
                "codec-response"
            ]
        )
    }

    func testHTTPClientUsesInjectedWireCodecForPOSTBodyAndResponseDecode() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("codec-response".utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let wireCodec = RecordingHTTPWireCodec()
        let client = makeClient(transport: transport, wireCodec: wireCodec)

        try await client.cancelRTCCall(context: makeContext(), callID: "call-1", reason: "user_cancel")

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.httpBody, Data("encoded-by-http-codec".utf8))
        let encoded = try XCTUnwrap(wireCodec.encodedObjects().first)
        XCTAssertEqual(encoded["reason"] as? String, "user_cancel")
        XCTAssertEqual(
            wireCodec.decodedTypeNames(),
            [
                "APIErrorEnvelope",
                "APILoginSecurityEnvelope",
                "APIEnvelope<EmptyPayload>"
            ]
        )
    }

    func testBackendUserMessageSanitizerHidesInternalAndSensitiveText() {
        let fallback = "服务暂不可用，请稍后重试"
        let unsafeMessages = [
            "Authorization: Bearer token-123 failed",
            "dsn=postgres://user:pass@db.example/tenant sqlstate 23505 duplicate key",
            "private key parse failed signature payload={\"token\":\"abc\"}",
            "stack trace: goroutine 12 panic: internal server error",
            "issuer.env loaded from issuer-data/private_seed",
            "object_key bucket secret_ref access_key unavailable",
            "raw JSON header contains token"
        ]

        for message in unsafeMessages {
            XCTAssertEqual(BackendUserMessageSanitizer.sanitize(message, fallback: fallback), fallback)
        }
        XCTAssertEqual(BackendUserMessageSanitizer.sanitize("请联系管理员确认企业状态", fallback: fallback), "请联系管理员确认企业状态")
        XCTAssertEqual(BackendUserMessageSanitizer.sanitize("rate limit state is temporarily unavailable", fallback: fallback), "服务繁忙，请稍后重试")
    }

    func testBackendUserMessageSanitizerHidesUnsafeLocalizedErrors() {
        let fallback = "操作失败，请稍后重试"
        let unsafe = UnsafeLocalizedDescriptionError(
            message: "Bearer credential failed dsn postgres payload private key SQLSTATE stack trace"
        )
        let sanitized = BackendUserMessageSanitizer.sanitize(error: unsafe, fallback: fallback)

        XCTAssertEqual(sanitized, fallback)
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("Bearer"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("dsn"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("payload"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("private key"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("SQLSTATE"))
        XCTAssertFalse(sanitized.localizedCaseInsensitiveContains("stack trace"))

        let safe = UnsafeLocalizedDescriptionError(message: "文件被系统占用，请稍后再试")
        XCTAssertEqual(BackendUserMessageSanitizer.sanitize(error: safe, fallback: fallback), "文件被系统占用，请稍后再试")
    }

    func testForbiddenBackendRawMessageIsSanitizedForUserFacingErrors() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"forbidden","message":"Authorization: Bearer token-123 failed with stack trace and private key payload"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 403
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("Expected forbidden response")
        } catch IMAPIError.businessForbidden(let code, let message, _) {
            XCTAssertEqual(code, "forbidden")
            XCTAssertEqual(message, "无权限执行该操作")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("token"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("Authorization"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("private key"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("payload"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPostRTCSignalUsesRTCTokenBearerAndEnvelopeBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"queued":true}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202,
                headers: ["X-Request-ID": "req-signal-1"]
            )
        ])
        let client = makeClient(transport: transport)
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "peer-uid",
            toDevice: "peer-device",
            kind: .offer,
            data: [
                "type": .string("offer"),
                "sdp": .string("redacted-sdp")
            ]
        )

        try await client.postRTCSignal(
            context: makeContext(),
            roomID: "room-1",
            rtcToken: "rtc-token-1",
            envelope: envelope
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/rtc/rooms/room-1/signal")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rtc-token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["to_uid"] as? String, "peer-uid")
        XCTAssertEqual(body["to_device"] as? String, "peer-device")
        XCTAssertEqual(body["kind"] as? String, "offer")
        let data = try XCTUnwrap(body["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "offer")
        XCTAssertEqual(data["sdp"] as? String, "redacted-sdp")
    }

    func testPostRTCQualitySamplesUsesDedicatedTokenAndPrivacyBoundedBody() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"schema_version":"rtc-quality-v1","accepted_count":1,"duplicate_count":0,"summary":{}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            )
        ])
        let client = makeClient(transport: transport)
        let token = try makeRTCQualityToken(scopes: ["rtc:room:join", "rtc:quality:write"])
        let sample = RTCQualitySample(
            sampledAt: Date(timeIntervalSince1970: 1_800_000_000),
            sampleSeq: 7,
            connectionRoute: "relay",
            candidateProtocol: "tls",
            rttMS: 80,
            jitterMS: 12,
            packetLossPct: 1.5,
            availableOutgoingBitrateKbps: 1_200,
            inboundBitrateKbps: 900,
            outboundBitrateKbps: 700,
            framesPerSecond: 24,
            framesDropped: 2,
            audioConcealmentPct: 0.5,
            freezeCount: 1
        )

        let result = try await client.postRTCQualitySamples(
            context: makeContext(),
            roomID: "room-quality-1",
            rtcToken: token,
            samples: [sample]
        )

        XCTAssertEqual(result.schemaVersion, "rtc-quality-v1")
        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/rtc/rooms/room-quality-1/quality-samples")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["schema_version"] as? String, "rtc-quality-v1")
        let samples = try XCTUnwrap(body["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["sample_seq"] as? Int, 7)
        XCTAssertEqual(samples[0]["connection_route"] as? String, "relay")
        XCTAssertEqual(samples[0]["candidate_protocol"] as? String, "tls")
        let keys = Set(samples[0].keys)
        for forbidden in ["ip", "address", "port", "sdp", "device", "username", "candidate_id", "media"] {
            XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }
        XCTAssertLessThan(try XCTUnwrap(request.httpBody).count, 64 * 1_024)
    }

    func testPostRTCQualitySamplesWithoutQualityScopeFailsClosedBeforeTransport() async throws {
        let transport = FakeHTTPTransport(results: [])
        let client = makeClient(transport: transport)
        let token = try makeRTCQualityToken(scopes: ["rtc:signal:send"])
        let sample = RTCQualitySample(
            sampledAt: Date(),
            sampleSeq: 1,
            connectionRoute: "unknown",
            candidateProtocol: "unknown",
            rttMS: 1,
            jitterMS: nil,
            packetLossPct: nil,
            availableOutgoingBitrateKbps: nil,
            inboundBitrateKbps: nil,
            outboundBitrateKbps: nil,
            framesPerSecond: nil,
            framesDropped: nil,
            audioConcealmentPct: nil,
            freezeCount: nil
        )

        do {
            _ = try await client.postRTCQualitySamples(
                context: makeContext(),
                roomID: "room-quality-1",
                rtcToken: token,
                samples: [sample]
            )
            XCTFail("Expected unscoped quality token to fail closed")
        } catch {
            XCTAssertTrue(transport.requests().isEmpty)
        }
    }

    func testRTCVideoAndClosingMutationsIncludeUniqueIdempotencyKeys() async throws {
        let callResponse = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"call":{"id":"call-1","room_id":"room-1","status":"ringing","call_type":"video"},"rtc_token":"rtc-token-1"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let emptyResponse = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [
            callResponse,
            callResponse,
            callResponse,
            callResponse,
            callResponse,
            emptyResponse,
            emptyResponse,
            emptyResponse,
            emptyResponse
        ])
        let preparation = CallsAcceptancePhasedHTTPTransport.providerPreparation()
        let phasedTransport = CallsAcceptancePhasedHTTPTransport(preparation: preparation, operation: transport)
        let client = makeClient(transport: phasedTransport)
        let context = makeContext()
        _ = try await client.rtcProvider(context: context)
        XCTAssertEqual(preparation.requests().map(\.url?.path), ["/api/rtc/provider"])
        phasedTransport.beginOperation()
        let capabilities = RTCDeviceCapabilities(
            audio: true,
            video: true,
            cameraAvailable: false
        )

        _ = try await client.createRTCVideoCall(
            context: context,
            calleeUID: "peer-uid",
            channelID: "direct-1",
            capabilities: capabilities
        )
        _ = try await client.createRTCCall(
            context: context,
            calleeUID: "peer-uid",
            callType: "audio",
            channelID: "direct-1"
        )
        _ = try await client.acceptRTCCall(
            context: context,
            callID: "call-1",
            mode: "video",
            capabilities: capabilities
        )
        _ = try await client.acceptRTCCall(context: context, callID: "call-1")
        _ = try await client.downgradeRTCCall(context: context, callID: "call-1", reason: "user_requested")
        try await client.rejectRTCCall(context: context, callID: "call-1")
        try await client.cancelRTCCall(context: context, callID: "call-1", reason: "user_cancel")
        try await client.hangupRTCCall(context: context, callID: "call-1", reason: "user_hangup")
        try await client.timeoutRTCCall(context: context, callID: "call-1", reason: "ring_timeout")

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 9)
        func requestBody(at index: Int) throws -> [String: Any] {
            let bodyData = try XCTUnwrap(requests[index].httpBody)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        }
        let audioCreateBody = try requestBody(at: 1)
        XCTAssertEqual(audioCreateBody["call_type"] as? String, "audio")
        let audioCreateCapabilities = try XCTUnwrap(audioCreateBody["device_capabilities"] as? [String: Any])
        XCTAssertEqual(audioCreateCapabilities["audio"] as? Bool, true)
        XCTAssertEqual(audioCreateCapabilities["video"] as? Bool, false)
        XCTAssertEqual(audioCreateCapabilities["camera_available"] as? Bool, false)
        let videoAcceptBody = try requestBody(at: 2)
        XCTAssertEqual(videoAcceptBody["accept_mode"] as? String, "video")
        let audioAcceptBody = try requestBody(at: 3)
        XCTAssertEqual(audioAcceptBody["accept_mode"] as? String, "audio")
        let audioCapabilities = try XCTUnwrap(audioAcceptBody["device_capabilities"] as? [String: Any])
        XCTAssertEqual(audioCapabilities["audio"] as? Bool, true)
        XCTAssertEqual(audioCapabilities["video"] as? Bool, false)
        XCTAssertEqual(audioCapabilities["camera_available"] as? Bool, false)
        var keys = Set<String>()
        for request in requests {
            let bodyData = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let key = try XCTUnwrap(body["idempotency_key"] as? String)
            XCTAssertTrue(key.hasPrefix("ios-"))
            XCTAssertGreaterThan(key.count, 20)
            XCTAssertFalse(key.localizedCaseInsensitiveContains("token"))
            keys.insert(key)
        }
        XCTAssertEqual(keys.count, requests.count)
    }

    func testRTCCapabilityStableCodesKeepTransientAndPermanentFailuresDistinct() {
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "rtc_license_capabilities_unavailable", media: .voice),
            "暂时无法确认语音通话权限，请稍后重试"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "rtc_license_capabilities_unavailable", media: .video),
            "暂时无法确认视频通话权限，请稍后重试"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "voice_call_not_enabled", media: .voice),
            "该企业未开通语音通话"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "video_call_not_enabled", media: .video),
            "该企业未开通视频通话"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "rtc_media_config_missing", media: .video),
            "视频通话媒体服务配置缺失，请联系管理员"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "rtc_ice_config_missing", media: .voice),
            "语音通话媒体服务配置缺失，请联系管理员"
        )
        XCTAssertEqual(
            rtcCapabilityFailureMessage(code: "rtc_turn_config_missing", media: .video),
            "视频通话媒体服务配置缺失，请联系管理员"
        )
        XCTAssertNil(rtcCapabilityFailureMessage(code: "permission_denied", media: .generic))
    }
}
