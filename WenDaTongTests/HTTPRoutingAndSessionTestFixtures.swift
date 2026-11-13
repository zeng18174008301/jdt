import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

struct AvatarProjectionEmptyMessageStore: MessageStore {
    let schemaVersion = 99

    func scopeKey(for context: IMAPIContext) -> String {
        "avatar-projection|\(context.deviceID)"
    }

    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { true }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { true }
    func remove(scope: String) {}
    func removeAll() {}
}

final class RecordingAvatarProjectionMessageStore: MessageStore, @unchecked Sendable {
    let schemaVersion = 99
    private let lock = NSLock()
    private var writes = 0

    func scopeKey(for context: IMAPIContext) -> String {
        "avatar-projection-recording|\(context.deviceID)"
    }

    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }

    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool {
        lock.withLock { writes += 1 }
        return true
    }

    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool {
        write(snapshot, scope: scope)
    }

    func remove(scope: String) {}
    func removeAll() {}

    func writeCount() -> Int {
        lock.withLock { writes }
    }
}

final class RuntimeRouteTestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value: UInt64

	init(nowMS: UInt64) { value = nowMS }

	func now() -> UInt64 { lock.withLock { value } }

	func advance(by milliseconds: UInt64) {
		lock.withLock {
			value = value > UInt64.max - milliseconds ? UInt64.max : value + milliseconds
		}
	}
}

final class RuntimeRouteBudgetTransport: HTTPTransport, @unchecked Sendable {
	enum Action {
		case failure(URLError.Code, advanceMS: UInt64)
		case response(status: Int, data: Data, advanceMS: UInt64)
		case responseWithinTimeout(status: Int, data: Data, advanceMS: UInt64)
	}

	private let lock = NSLock()
	private let clock: RuntimeRouteTestClock
	private var actions: [Action]
	private var captured: [URLRequest] = []

	init(clock: RuntimeRouteTestClock, actions: [Action]) {
		self.clock = clock
		self.actions = actions
	}

	func data(for request: URLRequest) async throws -> HTTPTransportResult {
		let action = lock.withLock { () -> Action in
			captured.append(request)
			return actions.isEmpty ? .failure(.resourceUnavailable, advanceMS: 0) : actions.removeFirst()
		}
		switch action {
		case let .failure(code, advanceMS):
			clock.advance(by: advanceMS)
			throw URLError(code)
		case let .response(status, data, advanceMS):
			clock.advance(by: advanceMS)
			return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: status)
		case let .responseWithinTimeout(status, data, advanceMS):
			let timeoutMS = UInt64(request.timeoutInterval * 1_000)
			clock.advance(by: min(advanceMS, timeoutMS))
			guard advanceMS < timeoutMS else { throw URLError(.timedOut) }
			return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: status)
		}
	}

	func upload(
		for request: URLRequest,
		from data: Data,
		delegate: URLSessionTaskDelegate?
	) async throws -> HTTPTransportResult {
		try await self.data(for: request)
	}

	func requestHosts() -> [String] { lock.withLock { captured.compactMap { $0.url?.host } } }
	func requests() -> [URLRequest] { lock.withLock { captured } }
	func requestURLs() -> [String] { lock.withLock { captured.compactMap { $0.url?.absoluteString } } }
	func requestTimeouts() -> [TimeInterval] { lock.withLock { captured.map(\.timeoutInterval) } }
}

final class RuntimeRouteURLProtocol: URLProtocol, @unchecked Sendable {
	typealias Handler = @Sendable (URLRequest) throws -> (status: Int, data: Data)
	private static let lock = NSLock()
	nonisolated(unsafe) private static var handler: Handler?
	nonisolated(unsafe) private static var requests: [URLRequest] = []

	static func install(_ handler: @escaping Handler) {
		lock.withLock {
			self.handler = handler
			requests = []
		}
	}

	static func reset() {
		lock.withLock {
			handler = nil
			requests = []
		}
	}

	static func requestHosts() -> [String] {
		lock.withLock { requests.compactMap { $0.url?.host } }
	}

	static func requestTimeouts() -> [TimeInterval] {
		lock.withLock { requests.map(\.timeoutInterval) }
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		let action = Self.lock.withLock { () -> Handler? in
			Self.requests.append(request)
			return Self.handler
		}
		do {
			guard let action else { throw URLError(.resourceUnavailable) }
			let result = try action(request)
			let response = HTTPURLResponse(
				url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": "application/json"]
			)!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: result.data)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override func stopLoading() {}
}

enum FakeHTTPTransportError: Error, Equatable {
    case responseQueueExhausted(method: String, url: String)
}

@MainActor
final class PostLoginSilentRealtimeTransport: RealtimeTransporting {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)?
    private(set) var isConnected = false

    func start(url: URL, token: String) {
        isConnected = true
    }

    func disconnect(shouldReconnect: Bool) {
        isConnected = false
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {}
}

final class AttachmentUploadTimeoutTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    var calls: [String] { lock.withLock { recordedCalls } }

    private func fail(_ phase: String) throws -> HTTPTransportResult {
        lock.withLock { recordedCalls.append(phase) }
        throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "SENSITIVE_SENTINEL https://private.invalid?token=secret"])
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult { try fail("presign") }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult { try fail("bytes") }
    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult { try fail("file") }
}

final class SyncDiagnosticHTTPTransport: HTTPTransport, @unchecked Sendable {
    static let tenantPaths = ["/api/tenant/context", "/api/tenant/workspaces", "/api/tenant/profile", "/api/tenant/me/profile"]
    private let lock = NSLock()
    private var failures: [String: Error]
    private var calls: [String: Int] = [:]
    var historyHTTPResult: HTTPTransportResult?
    var httpResults: [String: HTTPTransportResult] = [:]
    init(failures: [String: Error]) { self.failures = failures }
    func count(_ path: String) -> Int { lock.withLock { calls[path, default: 0] } }
    var refreshCount: Int { lock.withLock { calls.filter { $0.key.hasSuffix("/refresh") }.values.reduce(0, +) } }
    func setFailure(_ error: Error?, path: String) { lock.withLock { failures[path] = error } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        let failure = lock.withLock { () -> Error? in
            calls[path, default: 0] += 1
            return failures[path]
        }
        if let failure { throw failure }
        if path == "/api/im/sync", let historyHTTPResult { return historyHTTPResult.resolvingResponseURL(request.url) }
        if let result = httpResults[path] { return result.resolvingResponseURL(request.url) }
        // Failed refresh is terminal for the existing recovery attempt; never
        // contact a server or fabricate new authority in this diagnostics test.
        if path.hasSuffix("/refresh") { throw URLError(.timedOut) }
        let body: String
        switch path {
        case "/api/tenant/context":
            body = #"{"tenant_id":"tenant-1","im_uid":"uid-1","app_id":"ios-main","device_id":"device-1","tenant":{"tenant_id":"tenant-1","name":"Diagnostics fixture tenant","status":"active"}}"#
        case "/api/tenant/profile": body = #"{"tenant_id":"tenant-1","name":"Diagnostics fixture tenant","status":"active"}"#
        case "/api/tenant/me/profile": body = #"{"tenant_id":"tenant-1","im_uid":"uid-1","nickname":"Diagnostics fixture member"}"#
        case "/api/tenant/workspaces", "/api/im/sync": body = #"{"items":[]}"#
        default: throw URLError(.cancelled)
        }
        return HTTPTransportResult(data: Data("{\"ok\":true,\"data\":\(body)}".utf8), isHTTPResponse: true, statusCode: 200).resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}

final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias CapturedUpload = (request: URLRequest, body: Data)
    typealias CapturedFileUpload = (request: URLRequest, fileURL: URL, sizeBytes: Int64, hasProgressDelegate: Bool)

    private let lock = NSLock()
    private var queuedResults: [HTTPTransportResult]
    private var capturedRequests: [URLRequest] = []
    private var queuedUploadResults: [HTTPTransportResult]
    private var capturedUploads: [CapturedUpload] = []
    private var capturedFileUploads: [CapturedFileUpload] = []
    private var capturedEvents: [String] = []
    private let delayNanoseconds: UInt64

    init(results: [HTTPTransportResult], uploadResults: [HTTPTransportResult] = [], delayNanoseconds: UInt64 = 0) {
        self.queuedResults = results
        self.queuedUploadResults = uploadResults
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
            capturedEvents.append("request:\(request.httpMethod ?? "GET"):\(request.url?.path ?? "")")
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let result = try lock.withLock { () throws -> HTTPTransportResult in
            guard !queuedResults.isEmpty else {
                throw FakeHTTPTransportError.responseQueueExhausted(
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "<missing-url>"
                )
            }
            if queuedResults.count <= 1 {
                return queuedResults[0]
            }
            return queuedResults.removeFirst()
        }
        return result.resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedUploads.append((request: request, body: data))
            capturedEvents.append("upload:\(request.httpMethod ?? "PUT"):\(request.url?.path ?? "")")
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return lock.withLock {
            if queuedUploadResults.isEmpty {
                return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
            }
            if queuedUploadResults.count <= 1 {
                return queuedUploadResults[0]
            }
            return queuedUploadResults.removeFirst()
        }
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        lock.withLock {
            capturedFileUploads.append((request, fileURL, sizeBytes, delegate != nil))
            capturedEvents.append("file-upload:\(request.httpMethod ?? "PUT"):\(request.url?.path ?? "")")
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return lock.withLock {
            if queuedUploadResults.isEmpty {
                return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
            }
            if queuedUploadResults.count <= 1 {
                return queuedUploadResults[0]
            }
            return queuedUploadResults.removeFirst()
        }
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func uploads() -> [CapturedUpload] {
        lock.withLock { capturedUploads }
    }

    func fileUploads() -> [CapturedFileUpload] {
        lock.withLock { capturedFileUploads }
    }

    func events() -> [String] {
        lock.withLock { capturedEvents }
    }
}

final class DelayedRegistrationStatusHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResults: [HTTPTransportResult]
    private var capturedRequests: [URLRequest] = []
    private let statusDelayNanoseconds: UInt64

    init(results: [HTTPTransportResult], statusDelayNanoseconds: UInt64) {
        queuedResults = results
        self.statusDelayNanoseconds = statusDelayNanoseconds
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        if request.url?.path == "/api/platform/auth/register/status" {
            try? await Task.sleep(nanoseconds: statusDelayNanoseconds)
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"status":"SUCCESS"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ).resolvingResponseURL(request.url)
        }
        return try lock.withLock {
            guard !queuedResults.isEmpty else {
                throw FakeHTTPTransportError.responseQueueExhausted(
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "<missing-url>"
                )
            }
            return queuedResults.removeFirst().resolvingResponseURL(request.url)
        }
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

final class ScriptedMessageHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Action {
        case response(HTTPTransportResult)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var actions: [Action]
    private var capturedRequests: [URLRequest] = []

    init(actions: [Action]) {
        self.actions = actions
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let action = try lock.withLock { () throws -> Action in
            capturedRequests.append(request)
            guard !actions.isEmpty else {
                throw FakeHTTPTransportError.responseQueueExhausted(
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "<missing-url>"
                )
            }
            return actions.removeFirst()
        }
        switch action {
        case .response(let result):
            return result.resolvingResponseURL(request.url)
        case .failure(let code):
            throw URLError(code)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }
}

final class RecordingRememberedLoginCredentialStore: RememberedLoginCredentialPersisting {
    private var values: [RememberedLoginCredentialScope: RememberedLoginCredentials] = [:]
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentials? {
        values[scope]
    }

    @discardableResult
    func save(
        _ credentials: RememberedLoginCredentials,
        scope: RememberedLoginCredentialScope
    ) -> Bool {
        saveCount += 1
        values[scope] = credentials
        return true
    }

    func clear(scope: RememberedLoginCredentialScope) {
        clearCount += 1
        values.removeValue(forKey: scope)
    }
}

final class RecordingRememberedLoginPreferenceStore: RememberedLoginPreferencePersisting {
    private var values: [RememberedLoginCredentialScope: Bool] = [:]

    func value(scope: RememberedLoginCredentialScope) -> Bool? {
        values[scope]
    }

    func set(_ enabled: Bool, scope: RememberedLoginCredentialScope) {
        values[scope] = enabled
    }
}

final class InMemoryRememberedLoginSecretStore: RememberedLoginSecretStoring {
    private var values: [String: Data] = [:]
    private let failWrites: Bool
    private var failingWriteNumbers: Set<Int>
    private var failingDeleteNumbers: Set<Int>
    private var writeCount = 0
    private var deleteCount = 0

    init(
        failWrites: Bool = false,
        failingWriteNumbers: Set<Int> = [],
        failingDeleteNumbers: Set<Int> = []
    ) {
        self.failWrites = failWrites
        self.failingWriteNumbers = failingWriteNumbers
        self.failingDeleteNumbers = failingDeleteNumbers
    }

    var storedValueCount: Int { values.count }

    func data(service: String, account: String) -> Data? {
        values[key(service: service, account: account)]
    }

    func set(_ data: Data, service: String, account: String) -> Bool {
        writeCount += 1
        guard !failWrites, !failingWriteNumbers.contains(writeCount) else { return false }
        values[key(service: service, account: account)] = data
        return true
    }

    func delete(service: String, account: String) -> Bool {
        deleteCount += 1
        guard !failingDeleteNumbers.contains(deleteCount) else { return false }
        values.removeValue(forKey: key(service: service, account: account))
        return true
    }

    func failNextWrite(afterSuccessfulWrites: Int = 0) {
        failingWriteNumbers.insert(writeCount + afterSuccessfulWrites + 1)
    }

    func failNextDelete(afterSuccessfulDeletes: Int = 0) {
        failingDeleteNumbers.insert(deleteCount + afterSuccessfulDeletes + 1)
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

final class InMemoryProtectedSessionStore: IMProtectedSessionStoring {
    private var values: [String: String] = [:]
    private let failWrites: Bool
    private let failDeletes: Bool
    private let failingWriteNumbers: Set<Int>
    private let unreadableAfterWriteNumbers: Set<Int>
    private let onDeleteAll: (() -> Void)?
    private var writeCount = 0
    private(set) var deleteAllCount = 0

    init(
        failWrites: Bool = false,
        failDeletes: Bool = false,
        failingWriteNumbers: Set<Int> = [],
        unreadableAfterWriteNumbers: Set<Int> = [],
        onDeleteAll: (() -> Void)? = nil
    ) {
        self.failWrites = failWrites
        self.failDeletes = failDeletes
        self.failingWriteNumbers = failingWriteNumbers
        self.unreadableAfterWriteNumbers = unreadableAfterWriteNumbers
        self.onDeleteAll = onDeleteAll
    }

    var storedValueCount: Int { values.count }
    var writeAttemptCount: Int { writeCount }

    func string(forKey key: String) -> String? {
        unreadableAfterWriteNumbers.contains(writeCount) ? nil : values[key]
    }

    func setString(_ value: String, forKey key: String) -> Bool {
        writeCount += 1
        guard !failWrites, !failingWriteNumbers.contains(writeCount) else { return false }
        values[key] = value
        return true
    }

    func deleteString(forKey key: String) -> Bool {
        guard !failDeletes else { return false }
        values.removeValue(forKey: key)
        return true
    }

    func deleteAll() -> Bool {
        deleteAllCount += 1
        onDeleteAll?()
        guard !failDeletes else { return false }
        values.removeAll()
        return true
    }
}

final class SessionReauthenticationFailingRouteDefaults: UserDefaults, @unchecked Sendable {
    private let failureLock = NSLock()
    private var shouldFailSynchronization = false

    func failNextSynchronization() {
        failureLock.withLock { shouldFailSynchronization = true }
    }

    override func synchronize() -> Bool {
        let fail = failureLock.withLock {
            let fail = shouldFailSynchronization
            shouldFailSynchronization = false
            return fail
        }
        return fail ? false : super.synchronize()
    }
}

// WDT_IOS1_NATIVE_LOADED_IMAGE_OBSERVATION_20261111_BEGIN
import CryptoKit
import MachO

@MainActor
private enum A43RuntimeImageObservation {
    static var fileHashes: [String: String] = [:]

    static func uuid(_ header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let raw = UnsafeRawPointer(header)
        let headerSize = MemoryLayout<mach_header_64>.size
        var offset = headerSize
        let limit = headerSize + Int(header.pointee.sizeofcmds)
        for _ in 0..<header.pointee.ncmds {
            guard offset + MemoryLayout<load_command>.size <= limit else { return nil }
            let command = raw.advanced(by: offset).load(as: load_command.self)
            guard command.cmdsize >= MemoryLayout<load_command>.size,
                  offset + Int(command.cmdsize) <= limit else { return nil }
            if command.cmd == LC_UUID {
                guard command.cmdsize >= MemoryLayout<uuid_command>.size else { return nil }
                return UUID(uuid: raw.advanced(by: offset).load(as: uuid_command.self).uuid).uuidString
            }
            offset += Int(command.cmdsize)
        }
        return nil
    }
}

@MainActor
func captureA43RuntimeLoadedImages(function: String = #function) {
    var images: [[String: String]] = []
    for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
        let path = String(cString: name)
        guard path.contains("/WenDaTong.app/") else { continue }
        let last = URL(fileURLWithPath: path).lastPathComponent
        let role: String
        if last == "WenDaTong" { role = "App" }
        else if last == "WenDaTongTests" { role = "XCTest" }
        else if last.hasSuffix(".dylib") { role = "AppDylib" }
        else { continue }
        guard let uuid = A43RuntimeImageObservation.uuid(header) else {
            XCTFail("Loaded application image lacks readable in-memory LC_UUID"); continue
        }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let cacheKey = canonical + "|" + uuid
        let hash: String
        if let cached = A43RuntimeImageObservation.fileHashes[cacheKey] { hash = cached }
        else {
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: canonical), options: .mappedIfSafe) else {
                XCTFail("Loaded image backing file cannot be read"); continue
            }
            hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            A43RuntimeImageObservation.fileHashes[cacheKey] = hash
        }
        images.append(["role": role, "loadedPath": path, "canonicalPath": canonical,
                       "inMemoryLCUUID": uuid, "backingFileSHA256": hash])
    }
    XCTAssertEqual(images.filter { $0["role"] == "App" }.count, 1)
    XCTAssertEqual(images.filter { $0["role"] == "XCTest" }.count, 1)
    let payload: [String: Any] = ["schema": "IOS1_LOADED_IMAGE_BINDING_V1", "probeVersion": "DATA_IDENTITY_CACHE_OBSERVATION_V1_20261111",
                                "testCase": function, "pid": ProcessInfo.processInfo.processIdentifier, "images": images]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return XCTFail("Loaded image observation cannot be encoded") }
    print("[IOS1_LOADED_IMAGE_BINDING_V1] " + line)
    XCTContext.runActivity(named: "Actual loaded App and XCTest image identity") { activity in
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "IOS1 actual loaded images"; attachment.lifetime = .keepAlways
        activity.add(attachment)
    }
}
// WDT_IOS1_NATIVE_LOADED_IMAGE_OBSERVATION_20261111_END

// WDT_IOS1_ISOLATED_AUTHENTICATED_HTTP_FIXTURE_20261111_BEGIN
extension HTTPTransportTests {
    func makeIsolatedAuthenticatedHTTPState(
        transport: HTTPTransport,
        context: IMAPIContext,
        videoMediaClient: any VideoMediaClient = NoopVideoMediaClient()
    ) -> AppState {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-http-auth-\(UUID().uuidString)", isDirectory: true)
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            videoMediaClient: videoMediaClient,
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence,
            apiContextOverride: context
        )
        // Arrange the existing authenticated state without executing the login transition's RPCs.
        state.authenticationPresentationStore.setInitialAuthentication(true)
        // Keep this UUID backing while the fixture's original projection tasks/pools can still own it.
        return state
    }
}
// WDT_IOS1_ISOLATED_AUTHENTICATED_HTTP_FIXTURE_20261111_END

// WDT_IOS1_A04_ACTIVE_APP_POLICY_HTTP_FIXTURE_20261112_BEGIN
/// Seeds only this state's policy for tests whose HTTP assertions start after policy resolution.
@MainActor
func installActiveAppPolicyForHTTPFixture(on state: AppState) throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "ok": true,
        "data": [
            "app_id": IMAPIContext.normalizedIOSAppID(state.apiContext.appID),
            "platform": "ios",
            "status": "active",
            "allow_workspace_switch": true,
            "allow_default_tenant_join": false,
            "require_real_name": false,
            "require_phone_verification": false,
            "cache_ttl_seconds": 60,
        ],
    ])
    let response = try JSONDecoder().decode(APIEnvelope<RemoteAppCurrentPolicy>.self, from: data)
    let policy = try XCTUnwrap(response.data)
    state.appPolicyPresentationStore.installResolvedPolicy(policy)
    state.currentAppPolicyExpiresAt = Date().addingTimeInterval(TimeInterval(policy.cacheTTLSeconds))
}
// WDT_IOS1_A04_ACTIVE_APP_POLICY_HTTP_FIXTURE_20261112_END


extension HTTPTransportTests {
    func assertUnresolvedCurrentPolicy(platformBase: URL, tenantBase: URL, imBase: URL) async throws {
        let transport = FakeHTTPTransport(results: [])
        let client = IMAPIClient(
            platformBase: platformBase,
            tenantBase: tenantBase,
            imBase: imBase,
            bootstrapBases: [],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )
        do {
            _ = try await client.currentAppPolicy(appID: IMAPIContext.canonicalIOSAppID)
            XCTFail("Current policy requires a resolved platform route")
        } catch let IMAPIError.missingContext(field) {
            XCTAssertEqual(field, "bootstrap_host")
        }
        XCTAssertFalse(client.bootstrapResolutionCompleted)
        XCTAssertTrue(transport.requests().isEmpty)
    }

    func groupedCoreBootstrapResponse(appID: String, seed: URL, platformRoute: URL) throws -> Data {
        // Use the two configured HTTPS origins as coordinates for a fake response and transport.
        let seedHost = try XCTUnwrap(seed.host)
        var realtime = try XCTUnwrap(URLComponents(url: seed, resolvingAgainstBaseURL: false))
        realtime.scheme = "wss"
        realtime.path = "/im/ws"
        let endpoints: [IMRuntimeRouteService: String] = [
            .platformAPI: platformRoute.absoluteString, .tenantAPI: seed.absoluteString,
            .imAPI: seed.absoluteString, .imRealtime: try XCTUnwrap(realtime.url).absoluteString
        ]
        let routes = Dictionary(uniqueKeysWithValues: endpoints.map { service, endpoint in
            (service.rawValue, IMRuntimeRouteEndpointSet(preferred: [endpoint], backups: [],
                status: "ready", preferredSource: "app_preferred", backupSource: "common_platform_backup"))
        })
        let preferred = routes.mapValues(\.preferred)
        let policy = IMRuntimeRoutePolicy()
        let snapshot = IMRuntimeRouteSnapshot(
            contractVersion: 2, appID: appID, tenantID: nil, revision: 1, source: "app_bootstrap",
            status: "ready", configHash: "", services: routes, policy: policy, hashScope: .appBootstrap,
            bootstrapHost: seedHost, preferredEndpoints: preferred
        )
        let bootstrap = RemoteAppBootstrap(
            appID: appID, platform: "ios", status: "enabled", bootstrapHost: seedHost, appDomain: seedHost,
            configVersion: "grouped-core-fixture", ttlSeconds: 300,
            directory: .init(apiBaseURL: platformRoute.absoluteString),
            configHash: try XCTUnwrap(snapshot.recomputedConfigHash), contractVersion: 2, routeRevision: 1,
            routeSource: snapshot.source, routeStatus: snapshot.status, routes: routes,
            preferredEndpoints: preferred, routingPolicy: policy
        )
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bootstrap))
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": wire])
    }
}
