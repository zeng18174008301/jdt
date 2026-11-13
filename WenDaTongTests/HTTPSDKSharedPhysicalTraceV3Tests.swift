// WDT_IOS1_SDK_GET_V3_20261111_BEGIN
import Foundation
import XCTest
import IM4Core
import IM4Domain
@testable import WenDaTong

extension HTTPTransportTests {
    func testSDKV3RealURLSessionSharedGETLinksTwoLogicalCallersToOnePhysicalDelivery() async throws {
        captureA43RuntimeLoadedImages()
        let pair = try await sdkV3NativePair(traced: [true, true])
        XCTAssertEqual(pair.results.map(\.nickname), ["Native profile", "Native profile"])
        XCTAssertEqual(pair.results.map(\.failure), [nil, nil])
        let creator = try XCTUnwrap(pair.results[0].source)
        let follower = try XCTUnwrap(pair.results[1].source)
        XCTAssertNotEqual(creator, follower)
        assertSDKV3PhysicalPair(pair, deliveries: 1, decodes: 2, links: 2)
        XCTAssertEqual(pair.recorder.samples(.arrival).map { $0.context.operation }, [creator])
        XCTAssertEqual(Set(pair.recorder.samples(.decode).map { $0.context.operation }), [creator, follower])
        XCTAssertEqual(Set(pair.recorder.physicalLinks().map(\.operation)), [creator, follower])
        XCTAssertTrue(pair.recorder.physicalLinks().allSatisfy { $0.source == creator && $0.revision == 0 })
        XCTAssertTrue(pair.recorder.samples(.arrival).allSatisfy { !$0.onMainThread })
        XCTAssertTrue(pair.recorder.samples(.decode).allSatisfy(\.onMainThread))
        XCTAssertEqual(pair.codecMainFlags, Array(repeating: true, count: 6))
    }

    func testSDKV3RealURLSessionSharedGETKeepsNilProducerAndUntracedControls() async throws {
        captureA43RuntimeLoadedImages()
        let nilCreator = try await sdkV3NativePair(traced: [false, true])
        assertSDKV3PhysicalPair(nilCreator, deliveries: 0, decodes: 1, links: 0)
        XCTAssertNil(nilCreator.results[0].source)
        XCTAssertEqual(nilCreator.recorder.samples(.decode).map { $0.context.operation }, [try XCTUnwrap(nilCreator.results[1].source)])
        let nilFollower = try await sdkV3NativePair(traced: [true, false])
        assertSDKV3PhysicalPair(nilFollower, deliveries: 1, decodes: 1, links: 1)
        XCTAssertNil(nilFollower.results[1].source)
        let untraced = try await sdkV3NativePair(traced: [false, false])
        assertSDKV3PhysicalPair(untraced, deliveries: 0, decodes: 0, links: 0)
        XCTAssertEqual(untraced.results.map(\.nickname), ["Native profile", "Native profile"])
        XCTAssertEqual(untraced.results.map(\.source), [nil, nil])
    }

    func testSDKV3RealURLSessionSharedGETPreservesHTTPAndTransportErrors() async throws {
        captureA43RuntimeLoadedImages()
        let http = try await sdkV3NativePair(traced: [true, true], action: .response(401, Data(#"{"ok":false,"error":{"code":"expired_token","message":"expired"}}"#.utf8)))
        XCTAssertEqual(http.results.map(\.failure), [.unauthorized, .unauthorized])
        assertSDKV3PhysicalPair(http, deliveries: 1, decodes: 2, links: 2)
        let producer = try XCTUnwrap(http.recorder.samples(.arrival).first?.context.operation)
        XCTAssertTrue(http.recorder.physicalLinks().allSatisfy { $0.source == producer })
        XCTAssertEqual(Set(http.recorder.physicalLinks().map(\.operation)), Set(http.recorder.samples(.decode).map { $0.context.operation }))
        let transport = try await sdkV3NativePair(traced: [true, true], action: .failure(.networkConnectionLost))
        XCTAssertEqual(transport.results.map(\.failure), [.transport(URLError.networkConnectionLost.rawValue), .transport(URLError.networkConnectionLost.rawValue)])
        assertSDKV3PhysicalPair(transport, deliveries: 0, decodes: 0, links: 0, codecCalls: 0)
    }

    func testSDKV3CancelledLogicalGETDoesNotCancelSharedPhysicalProducerOrPeer() async throws {
        captureA43RuntimeLoadedImages()
        let pair = try await sdkV3NativePair(traced: [true, true], cancelCreator: true)
        // Original shared Task.value does not propagate a waiter's cancellation to its producer.
        XCTAssertEqual(pair.results.map(\.nickname), ["Native profile", "Native profile"])
        XCTAssertEqual(pair.results.map(\.failure), [nil, nil])
        assertSDKV3PhysicalPair(pair, deliveries: 1, decodes: 2, links: 2)
        XCTAssertEqual(pair.stopCallsBeforeRelease, 0)
        let creator = try XCTUnwrap(pair.results[0].source)
        XCTAssertTrue(pair.recorder.physicalLinks().allSatisfy { $0.source == creator })
    }

    // WDT_IOS1_SDK_DECODE_POLICY_FIXTURE_20261112_BEGIN
    func testSDKV3OriginalThreeDecodeBranchesEmitCapturedExecutionThroughSoleCoreBackend() async throws {
        captureA43RuntimeLoadedImages()
        let transport = FakeHTTPTransport(results: [
            .init(data: Data(#"{"ok":true,"data":{"conversations":[],"has_more":false}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            .init(data: Data(#"{"ok":true,"data":{"items":[],"has_more":false}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            .init(data: Data(#"{"ok":true,"data":{"value":7}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let context = makeContext()
        let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: context)
        let client = try XCTUnwrap(state.api as? IMAPIClient)
        let policyResponse = try JSONDecoder().decode(APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data)
        state.appPolicyPresentationStore.installResolvedPolicy(try XCTUnwrap(policyResponse.data))
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        let recorder = SDKV3EmissionRecorder()
        MessageDerivationInstrumentation.setEmissionObserver { recorder.append($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        _ = try await state.traceMessageHTTPRequest { try await client.conversationPage(context: context, cursor: "") }
        _ = try await state.traceMessageHTTPRequest { try await client.syncMessages(context: context, channelID: "g1", channelType: "group", afterSeq: 0, beforeSeq: nil, limit: 20) }
        let result = try await state.traceMessageHTTPRequest {
            let value: SDKV3Probe = try await client.request(base: URL(string: "https://tenant.example.test")!, path: "/api/tenant/me/profile")
            return value
        }
        XCTAssertEqual(result.value.value, 7)
        XCTAssertEqual(recorder.samples(.decode).map(\.onMainThread), [false, false, true])
        XCTAssertEqual(recorder.samples(.decode).count, 3)
        XCTAssertEqual(transport.events(), [
            "request:POST:/api/im/conversations/page",
            "request:POST:/api/im/sync",
            "request:GET:/api/tenant/me/profile"
        ])
        XCTAssertTrue(recorder.samples(.decode).allSatisfy { $0.uptimeNanoseconds > 0 && $0.durationNanoseconds > 0 })
        // Fake transport has no native receive point; it cannot fabricate a physical delivery sample.
        XCTAssertTrue(recorder.samples(.arrival).isEmpty)
        try attachSDKV3Emissions(recorder, name: "three-original-decode-branches")
    }
    // WDT_IOS1_SDK_DECODE_POLICY_FIXTURE_20261112_END

    func testSDKV3NativeOriginRestrictedOriginalAwaitCarriesSameCapturedContext() async throws {
        captureA43RuntimeLoadedImages()
        let gate = SDKV3URLGate(started: expectation(description: "origin-restricted native URLSession entered"))
        SDKV3GatedURLProtocol.install(gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKV3GatedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { gate.release(.failure(.cancelled)); SDKV3GatedURLProtocol.install(nil); session.invalidateAndCancel() }
        let context = makeContext()
        let state = makeIsolatedAuthenticatedHTTPState(transport: URLSessionHTTPTransport(session: session), context: context)
        let client = try XCTUnwrap(state.api as? IMAPIClient)
        let recorder = SDKV3EmissionRecorder()
        MessageDerivationInstrumentation.setEmissionObserver { recorder.append($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        let origin = URL(string: "https://tenant.example.test")!
        let task = Task { try await state.traceMessageHTTPRequest {
            let value: SDKV3Probe = try await client.request(base: origin, path: "/api/tenant/me/profile", bearer: context.imToken,
                propagateTaskCancellation: true, expectedResponseOrigin: origin, requestAuthority: context.authSessionFence)
            return value
        } }
        await fulfillment(of: [gate.started], timeout: 1)
        gate.release(.response(200, Data(#"{"ok":true,"data":{"value":7}}"#.utf8)))
        let result = try await task.value
        XCTAssertEqual(result.value.value, 7)
        XCTAssertEqual(gate.requests().count, 1)
        XCTAssertEqual(recorder.samples(.arrival).count, 1)
        XCTAssertEqual(recorder.samples(.decode).count, 1)
        XCTAssertEqual(recorder.physicalLinks().map(\.source), [result.sourceCorrelation])
        XCTAssertEqual(recorder.physicalLinks().map(\.operation), [result.sourceCorrelation])
        try attachSDKV3Emissions(recorder, name: "origin-restricted-original-native-await")
    }

    private func sdkV3NativePair(traced: [Bool], action: SDKV3URLAction = .response(200,
        Data(#"{"ok":true,"data":{"tenant_id":"tenant-1","im_uid":"uid-1","user_id":"user-1","nickname":"Native profile"}}"#.utf8)), cancelCreator: Bool = false) async throws -> SDKV3Pair {
        XCTAssertEqual(traced.count, 2)
        let gate = SDKV3URLGate(started: expectation(description: "original native shared GET physical producer entered"))
        SDKV3GatedURLProtocol.install(gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKV3GatedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { gate.release(.failure(.cancelled)); SDKV3GatedURLProtocol.install(nil); session.invalidateAndCancel() }
        let context = makeContext()
        let codec = SDKV3RecordingCodec()
        let nativeClient = makeClient(transport: URLSessionHTTPTransport(session: session),
                                      wireCodec: codec, runtimeRouteStore: isolatedRuntimeRouteStore())
        let state = AppState(api: nativeClient, messageStore: AvatarProjectionEmptyMessageStore(),
                             apiContextOverride: context)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let recorder = SDKV3EmissionRecorder()
        MessageDerivationInstrumentation.setEmissionObserver { recorder.append($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        func read(_ enabled: Bool) async -> SDKV3CallerResult {
            do {
                if enabled {
                    let result = try await state.traceMessageHTTPRequest { try await nativeClient.meProfile(context: context) }
                    return SDKV3CallerResult(nickname: result.value.nickname, source: result.sourceCorrelation, failure: nil)
                }
                let value = try await SDKHTTPTrace.$current.withValue(nil) { try await nativeClient.meProfile(context: context) }
                return SDKV3CallerResult(nickname: value.nickname, source: nil, failure: nil)
            } catch let error as URLError {
                return SDKV3CallerResult(nickname: nil, source: nil, failure: .transport(error.code.rawValue))
            } catch IMAPIError.unauthorized {
                return SDKV3CallerResult(nickname: nil, source: nil, failure: .unauthorized)
            } catch {
                return SDKV3CallerResult(nickname: nil, source: nil, failure: .other)
            }
        }
        let first = Task { await read(traced[0]) }
        await fulfillment(of: [gate.started], timeout: 1)
        let secondEntered = expectation(description: "second logical same-fence GET entered original MainActor SDK")
        let second = Task { secondEntered.fulfill(); return await read(traced[1]) }
        await fulfillment(of: [secondEntered], timeout: 1)
        // No suspension exists between the permitted me/profile gate and original raw shared-Task await.
        // The second MainActor call yields to this waiter only after that original await.
        if cancelCreator { first.cancel() }
        let stops = gate.stopCalls()
        gate.release(action)
        let results = [await first.value, await second.value]
        // All owned calls and their synchronous backend callbacks finish before observer removal.
        let pair = SDKV3Pair(results: results, recorder: recorder, requests: gate.requests(), codecMainFlags: codec.mainFlags(), stopCallsBeforeRelease: stops)
        try attachSDKV3Emissions(recorder, name: "real-native-shared-GET")
        return pair
    }

    private func assertSDKV3PhysicalPair(_ pair: SDKV3Pair, deliveries: Int, decodes: Int, links: Int, codecCalls: Int = 6,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pair.requests.count, 1, file: file, line: line)
        XCTAssertEqual(pair.recorder.samples(.arrival).count, deliveries, file: file, line: line)
        XCTAssertEqual(pair.recorder.samples(.decode).count, decodes, file: file, line: line)
        XCTAssertEqual(pair.recorder.physicalLinks().count, links, file: file, line: line)
        XCTAssertEqual(pair.codecMainFlags.count, codecCalls, file: file, line: line)
        XCTAssertTrue(pair.recorder.allSamples().allSatisfy { $0.uptimeNanoseconds > 0 && $0.durationNanoseconds > 0 }, file: file, line: line)
        XCTAssertEqual(pair.requests.first?.url?.path, "/api/tenant/me/profile", file: file, line: line)
        XCTAssertEqual(pair.requests.first?.httpMethod, "GET", file: file, line: line)
        XCTAssertNil(pair.requests.first?.httpBody, file: file, line: line)
        XCTAssertNil(pair.requests.first?.value(forHTTPHeaderField: "X-Source-Correlation"), file: file, line: line)
        XCTAssertNil(pair.requests.first?.value(forHTTPHeaderField: "X-SDK-Trace"), file: file, line: line)
    }

    private func attachSDKV3Emissions(_ recorder: SDKV3EmissionRecorder, name: String) throws {
        let attachment = XCTAttachment(data: try JSONEncoder().encode(recorder.transcript()), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private struct SDKV3Probe: Decodable, Sendable { let value: Int }
private enum SDKV3Failure: Equatable, Sendable { case unauthorized, transport(Int), other }
private struct SDKV3CallerResult: Sendable { let nickname: String?; let source: UInt64?; let failure: SDKV3Failure? }
private struct SDKV3Pair { let results: [SDKV3CallerResult]; let recorder: SDKV3EmissionRecorder; let requests: [URLRequest]; let codecMainFlags: [Bool]; let stopCallsBeforeRelease: Int }
private struct SDKV3Link: Codable { let operation: UInt64; let source: UInt64; let phase: String; let revision: UInt64 }
private struct SDKV3Transcript: Codable { let samples: [MessageDerivationSample]; let links: [SDKV3Link] }
private final class SDKV3EmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MessageDerivationInstrumentation.Emission] = []
    func append(_ value: MessageDerivationInstrumentation.Emission) { lock.withLock { values.append(value) } }
    func allSamples() -> [MessageDerivationSample] { lock.withLock { values.compactMap { if case .sample(let s) = $0 { return s }; return nil } } }
    func samples(_ phase: MessageDerivationSample.Phase) -> [MessageDerivationSample] { allSamples().filter { $0.phase == phase } }
    func physicalLinks() -> [SDKV3Link] { lock.withLock { values.compactMap { if case let .sourceLink(op, source, phase, revision) = $0 { return SDKV3Link(operation: op, source: source, phase: phase, revision: revision) }; return nil } }.filter { $0.phase == "physical_source" } }
    func transcript() -> SDKV3Transcript { SDKV3Transcript(samples: allSamples(), links: physicalLinks()) }
}
private final class SDKV3RecordingCodec: WireCodec, @unchecked Sendable {
    private let lock = NSLock(); private var flags: [Bool] = []
    private let codec = JSONWireCodec()
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { lock.withLock { flags.append(Thread.isMainThread) }; return try codec.decode(type, from: data) }
    func encodeJSONObject(_ object: Any) throws -> Data { try codec.encodeJSONObject(object) }
    func mainFlags() -> [Bool] { lock.withLock { flags } }
}
private enum SDKV3URLAction: Sendable { case response(Int, Data), failure(URLError.Code) }
private final class SDKV3URLGate: @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var protocols: [SDKV3GatedURLProtocol] = []
    private var action: SDKV3URLAction?
    private var stops = 0
    init(started: XCTestExpectation) { self.started = started }
    func enter(_ value: SDKV3GatedURLProtocol) {
        let current = lock.withLock {
            captured.append(value.request)
            if action == nil { protocols.append(value) }
            return action
        }
        started.fulfill()
        if let current { value.complete(current) }
    }
    func release(_ result: SDKV3URLAction) {
        let active: [SDKV3GatedURLProtocol] = lock.withLock { guard action == nil else { return [] }; action = result; let p = protocols; protocols = []; return p }
        active.forEach { $0.complete(result) }
    }
    func stop() { lock.withLock { stops += 1 } }
    func requests() -> [URLRequest] { lock.withLock { captured } }
    func stopCalls() -> Int { lock.withLock { stops } }
}
private final class SDKV3GatedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gate: SDKV3URLGate?
    private let instanceLock = NSLock()
    private var ownGate: SDKV3URLGate?
    static func install(_ value: SDKV3URLGate?) { lock.withLock { gate = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "tenant.example.test", let gate = Self.lock.withLock({ Self.gate }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        instanceLock.withLock { ownGate = gate }
        gate.enter(self)
    }
    override func stopLoading() { instanceLock.withLock { ownGate }?.stop() }
    func complete(_ action: SDKV3URLAction) {
        switch action {
        case let .response(status, data):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}
// WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_BEGIN
extension HTTPTransportTests {
    func testIncrementalConversationDecodePreservesEnvelopeFailuresAndExactRouteTypeGate() async throws {
        let context = makeContext()
        let path = "/api/im/conversations/sync"
        let base = try XCTUnwrap(URL(string: "https://im.example.test"))
        let statuses: [(Int, String, IMAPIError)] = [
            (200, #"{}"#, .emptyResponse),
            (200, #"{"ok":true,"data":null}"#, .emptyResponse),
            (200, #"{"ok":true,"data":{"conversations":"invalid"}}"#, .server(HTTPURLResponse.localizedString(forStatusCode: 200))),
            (200, #"{"ok":false,"error":{"code":"fixture_error","message":"Fixture rejected"}}"#, .server("Fixture rejected")),
            (401, #"{"ok":false,"error":{"code":"expired","message":"Session ended"}}"#, .unauthorized("Session ended"))
        ]
        let envelopeTypes = ["APIErrorEnvelope", "APILoginSecurityEnvelope", "APIEnvelope<RemoteConversationSyncData>"]

        for (status, input, expected) in statuses {
            let transport = FakeHTTPTransport(results: [
                .init(data: Data(input.utf8), isHTTPResponse: true, statusCode: status)
            ])
            let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec())
            let client = makeClient(transport: transport, wireCodec: codec, runtimeRouteStore: isolatedRuntimeRouteStore())
            do {
                _ = try await client.syncConversations(context: context, version: 7)
                XCTFail("Incremental sync unexpectedly accepted the fixture response")
            } catch let error as IMAPIError {
                switch (error, expected) {
                case (.emptyResponse, .emptyResponse):
                    break
                case (.server(let actual), .server(let expected)), (.unauthorized(let actual), .unauthorized(let expected)):
                    XCTAssertEqual(actual, expected)
                default:
                    XCTFail("Incremental sync changed its error case")
                }
            }
            XCTAssertEqual(codec.decodedTypeNames(), envelopeTypes)
            XCTAssertEqual(codec.decodedInputTexts(), Array(repeating: input, count: 3))
            XCTAssertEqual(codec.decodedOnMainThread(), [false, false, false])
            XCTAssertEqual(transport.requests().count, 1)
        }

        let typedPayload = Data(#"{"ok":true,"data":{"version":19,"conversations":[]}}"#.utf8)
        let genericPayload = Data(#"{"ok":true,"data":{"value":7}}"#.utf8)
        let transport = FakeHTTPTransport(results: [
            .init(data: typedPayload, isHTTPResponse: true, statusCode: 200),
            .init(data: genericPayload, isHTTPResponse: true, statusCode: 200)
        ])
        let codec = RecordingHTTPWireCodec(delegatingTo: JSONWireCodec())
        let client = makeClient(transport: transport, wireCodec: codec, runtimeRouteStore: isolatedRuntimeRouteStore())
        let typedGET: RemoteConversationSyncData = try await client.request(base: base, path: path)
        let genericPOST: SDKV3Probe = try await client.request(base: base, path: path, method: "POST")
        XCTAssertEqual(typedGET.version, 19)
        XCTAssertEqual(genericPOST.value, 7)
        XCTAssertEqual(codec.decodedOnMainThread(), Array(repeating: true, count: 6))
        XCTAssertEqual(transport.requests().map(\.httpMethod), ["GET", "POST"])
    }

    func testPrimarySnapshotConversationDecodeExecution() async throws {
        captureA43RuntimeLoadedImages()
        let recorder = SDKV3EmissionRecorder()
        MessageDerivationInstrumentation.setEmissionObserver { recorder.append($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        var timings: [PrimarySnapshotDecodeTiming] = []

        for sampleSize in [5, 25, 50] {
            for repeatIndex in 0..<3 {
                for route in PrimarySnapshotDecodeRoute.allCases {
                    let payload = try route.payload(rowCount: sampleSize)
                    let transport = PrimarySnapshotDecodeTransport(path: route.rawValue, payload: payload)
                    let context = makeContext(imUID: "decode-fixture-\(UUID().uuidString)")
                    let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: context)
                    let client = try XCTUnwrap(state.api as? IMAPIClient)
                    state.remoteSyncEngine.rememberRemoteConversationSyncVersion(7)
                    let trace = try await state.traceMessageHTTPRequest {
                        switch route {
                        case .incremental, .page:
                            let completed = await state.refreshRemoteSnapshot(silent: true, force: route == .page)
                            MainActor.preconditionIsolated()
                            XCTAssertTrue(completed, route.rawValue)
                            XCTAssertEqual(state.remoteSyncEngine.currentRemoteConversationSyncVersion(), 19)
                            XCTAssertTrue(state.hasLoadedRemoteSnapshot)
                            XCTAssertFalse(state.isConversationSnapshotPartial)
                            for index in 0..<sampleSize {
                                XCTAssertNotNil(state.conversationStore.conversation(id: "decode-row-\(index)"))
                            }
                            state.remoteSyncEngine.cancelSecondarySnapshotTasks()
                        case .messages:
                            let result = try await client.syncMessages(context: context, channelID: "decode-history",
                                channelType: "group", afterSeq: 0, beforeSeq: nil, limit: sampleSize)
                            XCTAssertEqual(result.items.count, sampleSize)
                        }
                    }
                    let samples = recorder.samples(.decode).filter { $0.context.operation == trace.sourceCorrelation }
                    XCTAssertEqual(samples.count, 1, route.rawValue)
                    let sample = try XCTUnwrap(samples.first)
                    XCTAssertFalse(sample.onMainThread, route.rawValue)
                    XCTAssertGreaterThan(sample.uptimeNanoseconds, 0)
                    XCTAssertGreaterThan(sample.durationNanoseconds, 0)
                    let request = try XCTUnwrap(transport.onlyRequest())
                    XCTAssertEqual(request.httpMethod, "POST")
                    let body = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                    )
                    switch route {
                    case .incremental:
                        XCTAssertEqual(body["version"] as? Int, 7)
                        XCTAssertEqual(body["limit"] as? Int, 50)
                    case .page:
                        XCTAssertEqual(body["limit"] as? Int, 100)
                    case .messages:
                        XCTAssertEqual(body["limit"] as? Int, sampleSize)
                    }
                    timings.append(PrimarySnapshotDecodeTiming(
                        route: route.rawValue, rows: sampleSize, bytes: payload.count, trial: repeatIndex,
                        operation: trace.sourceCorrelation, uptimeNanoseconds: sample.uptimeNanoseconds,
                        durationNanoseconds: sample.durationNanoseconds, onMainThread: sample.onMainThread
                    ))
                }
            }
        }

        XCTAssertTrue(recorder.samples(.arrival).isEmpty)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(timings), uniformTypeIdentifier: "public.json")
        attachment.name = "primary-snapshot-decode-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct PrimarySnapshotDecodeTiming: Encodable {
    let route: String
    let rows: Int
    let bytes: Int
    let trial: Int
    let operation: UInt64
    let uptimeNanoseconds: UInt64
    let durationNanoseconds: UInt64
    let onMainThread: Bool
}

private enum PrimarySnapshotDecodeRoute: String, CaseIterable {
    case incremental = "/api/im/conversations/sync"
    case page = "/api/im/conversations/page"
    case messages = "/api/im/sync"

    func payload(rowCount: Int) throws -> Data {
        func message(_ index: Int, channel: String) -> [String: Any] {
            [
                "message_id": "decode-message-\(index)", "channel_id": channel, "channel_type": "group",
                "channel_seq": index + 1, "from_uid": "fixture-author", "content_type": "text",
                "payload": ["text": String(repeating: "会话 preview \(index) ", count: 2 + index % 7)],
                "created_at": "2026-11-09T00:00:00Z"
            ]
        }

        let conversations: [[String: Any]] = (0..<rowCount).map { index in
            let channel = "decode-row-\(index)"
            return [
                "channel_id": channel, "channel_type": "group", "display_name": "Group \(index)",
                "last_msg_seq": index + 1, "last_read_seq": index, "unread_count": 1,
                "history_visible_from_seq": 1, "history_limited": index.isMultiple(of: 3),
                "last_message": message(index, channel: channel)
            ]
        }
        let body: [String: Any]
        switch self {
        case .incremental:
            body = ["conversations": conversations, "version": 19, "removed_conversations": [
                ["tenant_id": "tenant-1", "channel_id": "decode-removed", "channel_type": "group",
                 "reason": "removed", "version": 19]
            ]]
        case .page:
            body = ["conversations": conversations, "snapshot_id": "decode-fixture", "snapshot_version": 19,
                "has_more": false]
        case .messages:
            body = ["items": (0..<rowCount).map { message($0, channel: "decode-history") }, "has_more": false]
        }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": body], options: [.sortedKeys])
    }
}

private final class PrimarySnapshotDecodeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private let payload: Data
    private var requests: [URLRequest] = []

    init(path: String, payload: Data) {
        self.path = path
        self.payload = payload
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == path else { throw URLError(.cancelled) }
        lock.withLock { requests.append(request) }
        return HTTPTransportResult(data: payload, isHTTPResponse: true, statusCode: 200)
    }

    func onlyRequest() -> URLRequest? {
        lock.withLock { requests.count == 1 ? requests.first : nil }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}


extension HTTPTransportTests {
    func testIncrementalSnapshotCancellationAfterBytesSkipsCommitErrorsAndSecondaryWork() async throws {
        captureA43RuntimeLoadedImages()
        for reply in [try IncrementalDecodeTestTransport.success(), .unauthorized, .deviceRevoked] {
            let fixture = try incrementalDecodeFixture(replies: [reply], renewals: 0)
            defer { fixture.stop() }
            let refresh = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: false) }
            await fulfillment(of: [fixture.codec.entered], timeout: 2)
            refresh.cancel()
            fixture.codec.release()
            let applied = await refresh.value
            XCTAssertFalse(applied)
            XCTAssertTrue(fixture.state.isAuthenticated)
            XCTAssertEqual(fixture.state.apiContext.authSessionFence, fixture.original.authSessionFence)
            XCTAssertNil(fixture.state.syncFailureMessage)
            XCTAssertFalse(fixture.state.hasLoadedRemoteSnapshot)
            XCTAssertNil(fixture.state.conversationStore.conversation(id: "decode-row-0"))
            XCTAssertEqual(fixture.state.remoteSyncEngine.currentRemoteConversationSyncVersion(), 7)
            fixture.assertNoSecondaryWork()
            fixture.assertRequests([.incremental])
        }
    }

    func testIncrementalSnapshotRetiredFirst423DoesNotAffectRenewedAuthority() async throws {
        captureA43RuntimeLoadedImages()
        let fixture = try incrementalDecodeFixture(replies: [.locked], renewals: 1)
        defer { fixture.stop() }
        let refresh = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: false) }
        await fulfillment(of: [fixture.codec.entered], timeout: 2)
        let renewed = fixture.state.remoteSyncEngine.currentRemoteSnapshotRefreshSession()
        let next = try await fixture.renewCurrentAuthority()
        XCTAssertEqual(fixture.state.remoteSyncEngine.currentRemoteSnapshotRefreshSession(), renewed)
        fixture.codec.release()
        let applied = await refresh.value
        XCTAssertFalse(applied)
        fixture.assertUnaffectedAuthority(next)
        fixture.assertRequests([.incremental, .renewal])
    }

    func testIncrementalSnapshot401ReplaysOnceWithCommittedAuthority() async throws {
        captureA43RuntimeLoadedImages()
        for alreadyRenewed in [false, true] {
            let fixture = try incrementalDecodeFixture(
                replies: [.unauthorized, try IncrementalDecodeTestTransport.success()], renewals: 1
            )
            defer { fixture.stop() }
            let refresh = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: false) }
            await fulfillment(of: [fixture.codec.entered], timeout: 2)
            if alreadyRenewed { _ = try await fixture.renewCurrentAuthority() }
            fixture.codec.release()
            let applied = await refresh.value
            XCTAssertTrue(applied)
            XCTAssertEqual(fixture.state.remoteSyncEngine.currentRemoteConversationSyncVersion(), 19)
            XCTAssertTrue(fixture.state.hasLoadedRemoteSnapshot)
            XCTAssertNotNil(fixture.state.conversationStore.conversation(id: "decode-row-0"))
            XCTAssertNil(fixture.state.syncFailureMessage)
            XCTAssertTrue(fixture.state.apiContext.credentialsAdvanced(since: fixture.original.authSessionFence))
            fixture.assertRequests([.incremental, .renewal, .incremental])
            XCTAssertEqual(fixture.transport.incrementalBearerHeaders(), [
                "Bearer stale-im-token", "Bearer renewed-im-1"
            ])
        }
    }

    func testIncrementalSnapshotReplay423UsesItsOwnAttemptAuthority() async throws {
        captureA43RuntimeLoadedImages()
        for retireReplay in [false, true] {
            let fixture = try incrementalDecodeFixture(
                replies: [.unauthorized, .locked], renewals: retireReplay ? 2 : 1, blockedRequest: 2
            )
            defer { fixture.stop() }
            let refresh = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: false) }
            await fulfillment(of: [fixture.codec.entered], timeout: 2)
            fixture.assertRequests([.incremental, .renewal, .incremental])
            XCTAssertTrue(fixture.state.apiContext.credentialsAdvanced(since: fixture.original.authSessionFence))
            let replacement = retireReplay ? try await fixture.renewCurrentAuthority() : nil
            fixture.codec.release()
            let applied = await refresh.value
            XCTAssertFalse(applied)
            if let replacement {
                fixture.assertUnaffectedAuthority(replacement)
                fixture.assertRequests([.incremental, .renewal, .incremental, .renewal])
            } else {
                XCTAssertFalse(fixture.state.isAuthenticated)
                XCTAssertFalse(fixture.state.apiContext.hasIMSession)
                XCTAssertEqual(fixture.state.currentEnterprise.disabledReason, "account_locked")
                XCTAssertEqual(fixture.state.currentEnterprise.accountStatus, "locked")
                XCTAssertEqual(fixture.state.authScreen, .workspaceSelection)
                XCTAssertNil(fixture.state.syncFailureMessage)
                fixture.assertNoSecondaryWork()
                fixture.assertRequests([.incremental, .renewal, .incremental])
            }
        }
    }

    func testIncrementalSnapshotDeviceRevocationAppliesOnlyToCurrentAuthority() async throws {
        captureA43RuntimeLoadedImages()
        for retireRequest in [false, true] {
            let fixture = try incrementalDecodeFixture(replies: [.deviceRevoked], renewals: retireRequest ? 1 : 0)
            defer { fixture.stop() }
            let refresh = Task { await fixture.state.refreshRemoteSnapshot(silent: true, force: false) }
            await fulfillment(of: [fixture.codec.entered], timeout: 2)
            let replacement = retireRequest ? try await fixture.renewCurrentAuthority() : nil
            fixture.codec.release()
            let applied = await refresh.value
            XCTAssertFalse(applied)
            if let replacement {
                fixture.assertUnaffectedAuthority(replacement)
                fixture.assertRequests([.incremental, .renewal])
            } else {
                XCTAssertFalse(fixture.state.isAuthenticated)
                XCTAssertFalse(fixture.state.apiContext.hasIMSession)
                XCTAssertEqual(fixture.state.authScreen, .accountLogin)
                XCTAssertEqual(fixture.state.toast, DeviceRevocationDetector.logoutMessage)
                fixture.assertNoSecondaryWork()
                fixture.assertRequests([.incremental])
            }
        }
    }

    private func incrementalDecodeFixture(
        replies: [IncrementalDecodeTestTransport.Reply], renewals: Int, blockedRequest: Int = 1
    ) throws -> IncrementalDecodeFixture {
        let context = makeRefreshableMessageSendContext(deviceID: "incremental-decode-\(UUID().uuidString)")
        let store = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: store).isCommitted)
        let codec = IncrementalDecodeBlockingCodec(blockedRequest: blockedRequest)
        let transport = try IncrementalDecodeTestTransport(replies: replies, context: context, renewals: renewals)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incremental-decode-\(UUID().uuidString)")
        let state = AppState(
            api: makeClient(transport: transport, wireCodec: codec, runtimeRouteStore: isolatedRuntimeRouteStore()),
            realtimeClient: RealtimeClient(transport: FakeRealtimeWebSocketTransport(socket: FakeRealtimeWebSocketTask()),
                                           networkMonitorFactory: nil),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support")),
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
            protectedSessionStore: store, apiContextOverride: context
        )
        state.authenticationPresentationStore.setInitialAuthentication(true)
        let workspace = Enterprise(id: "tenant-1", name: "Decode fixture", code: "WXT000001", role: "member",
                                   status: "active", memberCount: 1, isDefault: false, accentHex: 0)
        state.setCurrentEnterprise(workspace)
        state.setEnterprises([workspace])
        state.remoteSyncEngine.rememberRemoteConversationSyncVersion(7)
        return IncrementalDecodeFixture(state: state, original: context, codec: codec, transport: transport, store: store)
    }
}

@MainActor
private struct IncrementalDecodeFixture {
    let state: AppState
    let original: IMAPIContext
    let codec: IncrementalDecodeBlockingCodec
    let transport: IncrementalDecodeTestTransport
    let store: InMemoryProtectedSessionStore

    func renewCurrentAuthority() async throws -> IMAPIContext {
        let context = state.apiContext
        let scope = state.remoteDataScopeKey(for: context)
        let renewed = await state.refreshStoredAuthSessionIfNeeded(reason: "incremental_decode_fixture", silent: true,
                                                                  context: context, scope: scope)
        XCTAssertTrue(renewed)
        let next = state.apiContext
        XCTAssertTrue(next.credentialsAdvanced(since: context.authSessionFence))
        XCTAssertEqual(state.remoteDataScopeKey(for: next), scope)
        XCTAssertEqual(IMAPIContext.load(sessionStore: store).authSessionFence, next.authSessionFence)
        return next
    }

    func assertUnaffectedAuthority(_ context: IMAPIContext) {
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.apiContext.hasIMSession)
        XCTAssertEqual(state.apiContext.authSessionFence, context.authSessionFence)
        XCTAssertEqual(IMAPIContext.load(sessionStore: store).authSessionFence, context.authSessionFence)
        XCTAssertEqual(state.currentEnterprise.id, "tenant-1")
        XCTAssertNil(state.syncFailureMessage)
        XCTAssertFalse(state.hasLoadedRemoteSnapshot)
        XCTAssertEqual(state.remoteSyncEngine.currentRemoteConversationSyncVersion(), 7)
        assertNoSecondaryWork()
    }

    func assertNoSecondaryWork() {
        for operation: SecondarySnapshotOperation in [.groups, .contacts, .profileDevice] {
            XCTAssertFalse(state.remoteSyncEngine.hasSecondarySnapshotTask(operation))
        }
    }

    func assertRequests(_ routes: [IncrementalDecodeTestTransport.Route]) {
        XCTAssertEqual(transport.routes(), routes)
        XCTAssertTrue(codec.observedBlockedDecodeOffMain())
        XCTAssertEqual(transport.incrementalVersions(), Array(repeating: 7, count: routes.filter { $0 == .incremental }.count))
    }

    func stop() {
        codec.release()
        state.stopInboxRefreshLoop()
        state.stopRTCCallRefreshLoop()
        state.remoteSyncEngine.cancelSecondarySnapshotTasks()
    }
}

private final class IncrementalDecodeBlockingCodec: WireCodec, @unchecked Sendable {
    let entered = XCTestExpectation(description: "typed decode entered after HTTP bytes arrived")
    private let lock = NSLock()
    private let releaseDecode = DispatchSemaphore(value: 0)
    private let blockedRequest: Int
    private let codec = JSONWireCodec()
    private var decodeCount = 0
    private var blockedDecodeOffMain = false

    init(blockedRequest: Int) { self.blockedRequest = blockedRequest }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == APIEnvelope<RemoteConversationSyncData>.self {
            let blocked = lock.withLock {
                decodeCount += 1
                guard decodeCount == blockedRequest else { return false }
                blockedDecodeOffMain = !Thread.isMainThread
                return true
            }
            if blocked {
                entered.fulfill()
                guard releaseDecode.wait(timeout: .now() + 8) == .success else { throw URLError(.timedOut) }
            }
        }
        return try codec.decode(type, from: data)
    }

    func encodeJSONObject(_ object: Any) throws -> Data { try codec.encodeJSONObject(object) }
    func observedBlockedDecodeOffMain() -> Bool { lock.withLock { blockedDecodeOffMain } }
    func release() { releaseDecode.signal() }
}

private final class IncrementalDecodeTestTransport: HTTPTransport, @unchecked Sendable {
    enum Route: String, Sendable {
        case incremental = "/api/im/conversations/sync"
        case renewal = "/api/platform/tenants/tenant-1/session/refresh"
    }

    struct Reply: Sendable {
        let code: Int
        let body: Data

        static let unauthorized = Reply(code: 401, body: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"Expired"}}"#.utf8))
        static let locked = Reply(code: 423, body: Data(#"{"ok":false,"error":{"code":"account_locked","message":"Account locked"}}"#.utf8))
        static let deviceRevoked = Reply(code: 403, body: Data(#"{"ok":false,"error":{"code":"device_revoked","message":"Device revoked"}}"#.utf8))
    }

    private let lock = NSLock()
    private var replies: [Route: [Reply]]
    private var requests: [(Route, URLRequest)] = []

    init(replies: [Reply], context: IMAPIContext, renewals: Int) throws {
        let session = try XCTUnwrap(context.tenantAuthSession)
        let rotations = try (0..<renewals).map { index in
            let next = index + 1
            let body: [String: Any] = ["ok": true, "data": [
                "im_token": "renewed-im-\(next)", "expires_at": 1_895_000_000,
                "tenant": ["tenant_id": session.tenantID, "name": "Decode fixture", "status": "active"],
                "member": ["tenant_id": session.tenantID, "account_id": context.accountID ?? "",
                    "im_uid": context.imUID ?? "", "status": "active", "role": "member"],
                "auth_session": ["session_id": session.sessionID, "refresh_token": "renewed-refresh-\(next)",
                    "tenant_id": session.tenantID, "app_id": context.appID, "device_id": context.deviceID,
                    "client_type": "ios", "token_type": "im", "auth_version": 4, "session_generation": next]
            ]]
            return Reply(code: 200, body: try JSONSerialization.data(withJSONObject: body))
        }
        self.replies = [.incremental: replies, .renewal: rotations]
    }

    static func success() throws -> Reply {
        Reply(code: 200, body: try PrimarySnapshotDecodeRoute.incremental.payload(rowCount: 1))
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard let path = request.url?.path, let route = Route(rawValue: path) else { throw URLError(.cancelled) }
        return try lock.withLock {
            requests.append((route, request))
            guard let reply = replies[route]?.first else { throw URLError(.resourceUnavailable) }
            replies[route]?.removeFirst()
            return HTTPTransportResult(data: reply.body, isHTTPResponse: true, statusCode: reply.code, responseURL: request.url)
        }
    }

    func routes() -> [Route] { lock.withLock { requests.map { $0.0 } } }

    func incrementalBearerHeaders() -> [String?] {
        lock.withLock { requests.filter { $0.0 == .incremental }.map { $0.1.value(forHTTPHeaderField: "Authorization") } }
    }

    func incrementalVersions() -> [Int?] {
        lock.withLock {
            requests.filter { $0.0 == .incremental }.map { _, request in
                guard let data = request.httpBody,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return body["version"] as? Int
            }
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_END
// WDT_IOS1_SDK_GET_V3_20261111_END
