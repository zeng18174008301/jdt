import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

final class GroupNicknameMutationRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var membersCallCount = 0
    private var prePatchMemberContinuation: CheckedContinuation<Void, Never>?
    private var prePatchMemberReleased = false
    private var postCommitMemberCompleted = false

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let memberOrdinal: Int? = lock.withLock {
            capturedRequests.append(request)
            guard request.httpMethod == "GET",
                  request.url?.path.hasSuffix("/groups/group-a/members") == true else {
                return nil
            }
            membersCallCount += 1
            return membersCallCount
        }

        if memberOrdinal == 1 {
            await waitForPrePatchMemberRelease()
        } else if memberOrdinal == 2 {
            try await Task.sleep(nanoseconds: 180_000_000)
        }

        let result = response(for: request, memberOrdinal: memberOrdinal)
        if memberOrdinal == 2 {
            lock.withLock {
                postCommitMemberCompleted = true
            }
        }
        return result
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func memberRequestCount() -> Int {
        lock.withLock { membersCallCount }
    }

    func completedPostCommitMemberResponse() -> Bool {
        lock.withLock { postCommitMemberCompleted }
    }

    func releasePrePatchMemberResponse() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            prePatchMemberReleased = true
            let continuation = prePatchMemberContinuation
            prePatchMemberContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func waitForPrePatchMemberRelease() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if prePatchMemberReleased {
                    return true
                }
                prePatchMemberContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func response(
        for request: URLRequest,
        memberOrdinal: Int?
    ) -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        let body: String
        switch (request.httpMethod ?? "GET", path) {
        case ("PATCH", _) where path.hasSuffix("/groups/group-a/members/me"):
            body = #"{"ok":true,"data":{"group_id":"group-a","im_uid":"uid-1","group_nickname":"提交后的群昵称","raw_nickname":"我的全局昵称","display_name":"提交后的群昵称","display_name_source":"group_nickname","updated_at":"2026-07-28T12:00:00Z"}}"#
        case ("GET", _) where path.hasSuffix("/groups/group-a/summary"):
            body = #"{"ok":true,"data":{"group":{"group_id":"group-a","name":"A 群"},"my_role":"member","member_preview":[]}}"#
        case ("GET", _) where path.hasSuffix("/groups/group-a/members"):
            let nickname = memberOrdinal == 1 ? "提交前旧群昵称" : "提交后的群昵称"
            body = #"{"ok":true,"data":{"items":[{"im_uid":"uid-2","nickname":"第一页成员","role":"member"}],"self_member":{"im_uid":"uid-1","nickname":"我的全局昵称","group_nickname":"\#(nickname)","display_name":"\#(nickname)","display_name_source":"group_nickname","role":"member"},"has_more":false}}"#
        case ("GET", _) where path.hasSuffix("/announcements/current"):
            body = #"{"ok":true,"data":{"id":"","group_id":"group-a"}}"#
        default:
            body = #"{"ok":true,"data":{"items":[]}}"#
        }
        return HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }
}

@MainActor
final class PeerWaitVideoMediaClient: VideoMediaClient {
    var isAvailable: Bool { true }
    var cameraAvailable: Bool { true }
    private(set) var stopReasons: [String] = []
    private(set) var startContexts: [VideoMediaSessionContext] = []

    func preparePreview(preferFrontCamera: Bool) async throws {}

    func start(
        context: VideoMediaSessionContext,
        cameraEnabled: Bool
    ) async throws -> AsyncStream<RTCVideoMediaEvent> {
        startContexts.append(context)
        return AsyncStream<RTCVideoMediaEvent> { continuation in
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {}
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {}
    func setCameraEnabled(_ isEnabled: Bool) async throws {}
    func switchCamera() async throws {}
    func downgradeToAudio() async throws {}
    func applicationDidEnterBackground() async {}
    func applicationWillEnterForeground() async throws {}
    func reconcileAudioSessionAfterSystemEvent() async throws {}

    func stop(reason: String) async {
        stopReasons.append(reason)
    }
}

final class RecordingHTTPWireCodec: WireCodec, @unchecked Sendable {
    // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
    private let delegatedCodec: (any WireCodec)?
    private let beforeConversationPageDecode: (@Sendable (Data) -> Void)?
    init(delegatingTo codec: (any WireCodec)? = nil, beforeConversationPageDecode: (@Sendable (Data) -> Void)? = nil) {
        delegatedCodec = codec
        self.beforeConversationPageDecode = beforeConversationPageDecode
    }
    // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END
    private let lock = NSLock()
    private var capturedEncodedObjects: [[String: Any]] = []
    private var capturedDecodedTypeNames: [String] = []
    private var capturedDecodedInputTexts: [String] = []
    // WDT_CHAT_RESOURCE_PERF_20261023
    private var capturedDecodeMainThreads: [Bool] = []

    func encodeJSONObject(_ object: Any) throws -> Data {
        if let dictionary = object as? [String: Any] {
            lock.withLock {
                capturedEncodedObjects.append(dictionary)
            }
        }
        if let delegatedCodec { return try delegatedCodec.encodeJSONObject(object) } // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110
        return Data("encoded-by-http-codec".utf8)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let typeName = String(describing: T.self)
        lock.withLock {
            capturedDecodedTypeNames.append(typeName)
            capturedDecodedInputTexts.append(String(data: data, encoding: .utf8) ?? "")
            // WDT_CHAT_RESOURCE_PERF_20261023
            capturedDecodeMainThreads.append(Thread.isMainThread)
        }
        // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
        if let delegatedCodec {
            if T.self == APIEnvelope<RemoteConversationPage>.self { beforeConversationPageDecode?(data) }
            return try delegatedCodec.decode(type, from: data)
        }
        // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END
        if typeName == "APILoginSecurityEnvelope" {
            throw TestWireCodecError.unsupportedType(typeName)
        }
        let payload: Data
        if typeName == "APIEnvelope<EmptyPayload>" {
            payload = Data(#"{"ok":true,"data":{}}"#.utf8)
        } else {
            payload = Data(#"{"ok":true,"data":{"items":[],"total":0}}"#.utf8)
        }
        return try JSONDecoder().decode(type, from: payload)
    }

    func encodedObjectCount() -> Int {
        lock.withLock { capturedEncodedObjects.count }
    }

    func encodedObjects() -> [[String: Any]] {
        lock.withLock { capturedEncodedObjects }
    }

    func decodedTypeNames() -> [String] {
        lock.withLock { capturedDecodedTypeNames }
    }

    func decodedInputTexts() -> [String] {
        lock.withLock { capturedDecodedInputTexts }
    }

    // WDT_CHAT_RESOURCE_PERF_20261023
    func decodedOnMainThread() -> [Bool] {
        lock.withLock { capturedDecodeMainThreads }
    }
}

private enum TestWireCodecError: Error {
    case unsupportedType(String)
}

final class RegistrationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    private var recordedDelays: [TimeInterval] = []

    init(initialTime: TimeInterval = 0) {
        current = initialTime
    }

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            recordedDelays.append(seconds)
            current += seconds
        }
    }

    func elapse(by seconds: TimeInterval) {
        lock.withLock {
            current += seconds
        }
    }

    func delays() -> [TimeInterval] {
        lock.withLock { recordedDelays }
    }
}

final class RegistrationStatusClockAdvancingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: RegistrationTestClock
    private let responseElapsed: TimeInterval
    private let policyResult: HTTPTransportResult
    private var capturedRequests: [URLRequest] = []

    init(clock: RegistrationTestClock, responseElapsed: TimeInterval, policyResult: HTTPTransportResult) {
        self.clock = clock
        self.responseElapsed = responseElapsed
        self.policyResult = policyResult
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        if request.url?.path == "/api/platform/auth/register" {
            return HTTPTransportResult(data: Data("unavailable".utf8), isHTTPResponse: true, statusCode: 503)
                .resolvingResponseURL(request.url)
        }
        guard request.url?.path == "/api/platform/auth/register/status" else {
            return policyResult.resolvingResponseURL(request.url)
        }
        clock.elapse(by: responseElapsed)
        return HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"status":"SUCCESS"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ).resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw FakeHTTPTransportError.responseQueueExhausted(
            method: request.httpMethod ?? "PUT",
            url: request.url?.absoluteString ?? "<missing-url>"
        )
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw FakeHTTPTransportError.responseQueueExhausted(
            method: request.httpMethod ?? "PUT",
            url: request.url?.absoluteString ?? "<missing-url>"
        )
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
extension HTTPTransportTests {
    func testConversationPageActualRouteDecodesExactDTOOffMainAndPreservesRequest() async throws {
        let text = #"{"ok":true,"data":{"conversations":[{"channel_id":"g1","channel_type":"group","last_msg_seq":9007199254740991,"last_message":{"message_id":"m1","channel_id":"g1","channel_type":"group","created_at":"2026-11-09T12:34:56.123Z"}}],"has_more":false,"snapshot_id":"s","snapshot_version":17}}"#
        let data = Data(text.utf8)
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)])
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec())
        let client = makeClient(transport: transport, wireCodec: codec)
        XCTAssertTrue(Thread.isMainThread)
        let page = try await client.conversationPage(context: makeContext(), cursor: "opaque-cursor")
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(codec.decodedTypeNames(), ["APIErrorEnvelope", "APILoginSecurityEnvelope", "APIEnvelope<RemoteConversationPage>"])
        XCTAssertEqual(codec.decodedInputTexts(), Array(repeating: text, count: 3))
        XCTAssertEqual(codec.decodedOnMainThread(), [false, false, false])
        XCTAssertEqual(page.conversations.first?.lastMsgSeq, 9007199254740991)
        XCTAssertEqual(page.conversations.first?.lastMessage?.createdAt, "2026-11-09T12:34:56.123Z")
        XCTAssertEqual(page.snapshotID, "s"); XCTAssertEqual(page.snapshotVersion, 17)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(transport.requests().count, 1); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/im/conversations/page")
        let body = try XCTUnwrap(codec.encodedObjects().first)
        XCTAssertEqual(body["limit"] as? Int, 100); XCTAssertEqual(body["cursor"] as? String, "opaque-cursor")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + (makeContext().imToken ?? ""))
    }

    func testTypedPageDecodeKeepsOriginalEnvelopeErrorDateAndNumberSemantics() async {
        let client = makeClient(transport: FakeHTTPTransport(results: []))
        let samples = [
            #"{"ok":true,"data":{"conversations":[{"channel_id":"g","channel_type":"group","last_msg_seq":"9007199254740991","updated_at":"2026-11-09T12:34:56+07:00","last_message":{"message_id":"m","channel_id":"g","channel_type":"group","created_at":"invalid-date-kept-as-wire-value"}}],"has_more":false,"snapshot_id":"s","snapshot_version":42}}"#,
            #"{"ok":false,"error":{"code":"rate_limited","message":"limited","retry_after_seconds":12,"locked_until":"2026-11-10T00:00:00Z"}}"#,
            #"{"code":"account_locked","message":"Locked","data":{"failed_attempts":"3","locked":true,"ban_until":"tomorrow"}}"#,
            #"{"ok":true,"data":{"conversations":"invalid","has_more":false}}"#,
            "not-json"
        ]
        for sample in samples {
            let data = Data(sample.utf8)
            let before: IMAPIClient.DecodedAPIResponse<RemoteConversationPage> = client.decodeAPIResponse(from: data)
            let after = await client.decodeConversationPageResponseOffMain(from: data)
            XCTAssertEqual(before.envelope?.ok, after.envelope?.ok)
            XCTAssertEqual(before.envelope?.data?.hasMore, after.envelope?.data?.hasMore)
            XCTAssertEqual(before.envelope?.data?.snapshotID, after.envelope?.data?.snapshotID)
            XCTAssertEqual(before.envelope?.data?.snapshotVersion, after.envelope?.data?.snapshotVersion)
            XCTAssertEqual(before.envelope?.data?.conversations.first?.lastMsgSeq, after.envelope?.data?.conversations.first?.lastMsgSeq)
            XCTAssertEqual(before.envelope?.data?.conversations.first?.updatedAt, after.envelope?.data?.conversations.first?.updatedAt)
            XCTAssertEqual(before.envelope?.data?.conversations.first?.lastMessage?.createdAt, after.envelope?.data?.conversations.first?.lastMessage?.createdAt)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.code, after.errorEnvelope?.resolvedError?.code)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.message, after.errorEnvelope?.resolvedError?.message)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.retryAfterSeconds, after.errorEnvelope?.resolvedError?.retryAfterSeconds)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.lockedUntil, after.errorEnvelope?.resolvedError?.lockedUntil)
            XCTAssertEqual(before.loginSecurityEnvelope?.resolvedError?.code, after.loginSecurityEnvelope?.resolvedError?.code)
            XCTAssertEqual(before.loginSecurityEnvelope?.data, after.loginSecurityEnvelope?.data)
        }
    }
}
// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END
