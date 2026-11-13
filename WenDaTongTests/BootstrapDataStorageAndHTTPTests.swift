// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_BEGIN
import Foundation
import IM4Data
import Security
import XCTest
@testable import WenDaTong

@MainActor
final class BootstrapDataStorageAndHTTPTests: XCTestCase {
    func testPreloginEnvelopeFirstReadReopenRerunAndDamagedJSON() async throws {
        let directory = try ownedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("last-good.json")
        let store = WenDaTong.PreloginSecureLastGoodStore(scopeHash: "synthetic-scope", fileURL: url)
        let missing = try await store.loadEnvelope()
        XCTAssertNil(missing)
        let value = envelope(version: 1)
        try await store.saveEnvelope(value)
        let firstBytes = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["scopeHash", "artifact", "keyState", "currentPointer", "savedAt"]))
        XCTAssertEqual(json["artifact"] as? String, Data([1]).base64EncodedString())
        let reopened = WenDaTong.PreloginSecureLastGoodStore(scopeHash: "synthetic-scope", fileURL: url)
        let loaded = try await reopened.loadEnvelope()
        XCTAssertEqual(loaded?.artifact, value.artifact)
        XCTAssertEqual(loaded?.savedAt, value.savedAt)
        try await reopened.saveEnvelope(value)
        let repeated = try await store.loadEnvelope()
        XCTAssertEqual(repeated?.scopeHash, "synthetic-scope")
        try Data("damaged-json".utf8).write(to: url)
        do {
            _ = try await reopened.loadEnvelope()
            XCTFail("Damaged existing bytes must remain a decoding failure")
        } catch is DecodingError {}
        XCTAssertEqual(try Data(contentsOf: url), Data("damaged-json".utf8))
    }

    func testPreloginFailedAtomicReplacePreservesOldEnvelope() async throws {
        let directory = try ownedDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("last-good.json")
        let store = WenDaTong.PreloginSecureLastGoodStore(scopeHash: "synthetic-scope", fileURL: url)
        try await store.saveEnvelope(envelope(version: 1))
        let oldBytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            try await store.saveEnvelope(envelope(version: 2))
            XCTFail("A read-only parent must reject atomic replacement")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), oldBytes)
    }

    func testSyntheticCheckpointFirstReadUpdateAndCorruptionOrMissingEntitlement() async throws {
        let directory = try ownedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = "im4.synthetic.bootstrap-data-tests.\(UUID().uuidString)"
        let scope = "synthetic-checkpoint"
        let service = WenDaTong.PreloginSecureLastGoodStore.keychainServiceName(bundleIdentifier: identifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope
        ]
        defer { SecItemDelete(query as CFDictionary) }
        let store = WenDaTong.PreloginSecureLastGoodStore(
            scopeHash: scope, fileURL: directory.appendingPathComponent("last-good.json"), bundleIdentifier: identifier
        )
        let value = WenDaTong.PreloginTrustCheckpoint(
            scopeHash: scope, recoveryGeneration: 3, recoveryHash: "synthetic-recovery",
            fencingGeneration: 5, configVersion: 7, payloadHash: "synthetic-payload",
            lastTrustedWallClock: Date(timeIntervalSince1970: 1_700_000_000),
            lastNetworkSavedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var probe = query
        probe[kSecReturnData as String] = true
        let initialStatus = SecItemCopyMatching(probe as CFDictionary, nil)
        if initialStatus == errSecMissingEntitlement {
            do {
                _ = try await store.loadCheckpoint()
                XCTFail("An inaccessible checkpoint must fail closed")
            } catch {
                XCTAssertEqual(error as? PreloginBootstrapError, .allSourcesUnavailable)
            }
            do {
                try await store.saveCheckpoint(value)
                XCTFail("A checkpoint write without entitlement must fail closed")
            } catch {
                XCTAssertEqual(error as? PreloginBootstrapError, .allSourcesUnavailable)
            }
            return
        }
        XCTAssertEqual(initialStatus, errSecItemNotFound)
        let missing = try await store.loadCheckpoint()
        XCTAssertNil(missing)
        try await store.saveCheckpoint(value)
        let first = try await store.loadCheckpoint()
        XCTAssertEqual(first, value)
        try await store.saveCheckpoint(value)
        let reopened = WenDaTong.PreloginSecureLastGoodStore(
            scopeHash: scope, fileURL: directory.appendingPathComponent("last-good.json"), bundleIdentifier: identifier
        )
        let rerun = try await reopened.loadCheckpoint()
        XCTAssertEqual(rerun, value)
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("broken".utf8)] as CFDictionary), errSecSuccess)
        do {
            _ = try await reopened.loadCheckpoint()
            XCTFail("A corrupt checkpoint must not become an absent checkpoint")
        } catch is DecodingError {}
    }

    func testAppHTTPSConsumerAcceptsExactLimitAndRejectsStatusURLAndBothSizeBounds() async throws {
        let client = makeClient()
        let seed = seed()
        let bytes = try await client.get(seed.baseURL.appendingPathComponent("exact.json"), constrainedTo: seed)
        XCTAssertEqual(bytes, Data(repeating: 0x61, count: PreloginStrictJSON.maxBytes))
        let empty = try await client.get(seed.baseURL.appendingPathComponent("empty.json"), constrainedTo: seed)
        XCTAssertTrue(empty.isEmpty)
        for path in ["status.json", "redirect.json", "response-url.json", "header-too-large.json", "stream-too-large.json"] {
            do {
                _ = try await client.get(seed.baseURL.appendingPathComponent(path), constrainedTo: seed)
                XCTFail("Must reject \(path)")
            } catch {
                XCTAssertEqual(error as? PreloginBootstrapError, .allSourcesUnavailable, path)
            }
        }
    }

    func testAppHTTPSConsumerRejectsUnconstrainedURLsAndPreservesTransportFailure() async throws {
        let client = makeClient()
        let seed = seed()
        for text in [
            "http://bootstrap-data.example.test/config/empty.json",
            "https://other.example.test/config/empty.json",
            "https://bootstrap-data.example.test:444/config/empty.json",
            "https://bootstrap-data.example.test/config-sibling/empty.json",
            "https://user@bootstrap-data.example.test/config/empty.json",
            "https://bootstrap-data.example.test/config/empty.json?query=1",
            "https://bootstrap-data.example.test/config/empty.json#fragment"
        ] {
            do {
                _ = try await client.get(try XCTUnwrap(URL(string: text)), constrainedTo: seed)
                XCTFail("Must reject \(text)")
            } catch {
                XCTAssertEqual(error as? PreloginBootstrapError, .allSourcesUnavailable)
            }
        }
        do {
            _ = try await client.get(seed.baseURL.appendingPathComponent("transport-error.json"), constrainedTo: seed)
            XCTFail("Transport failure must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertNil(PreloginRedirectPolicy.requestToFollow(
            originalURL: seed.baseURL, proposedRequest: URLRequest(url: seed.baseURL.appendingPathComponent("empty.json"))
        ))
    }

    func testAppHTTPSConsumerCancellationStopsPendingStream() async throws {
        let started = expectation(description: "The real URLSession starts its pending request")
        await BootstrapHTTPSStartGate.shared.observe(started)
        let client = makeClient()
        let seed = seed()
        let task = Task { try await client.get(seed.baseURL.appendingPathComponent("pending.json"), constrainedTo: seed) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not produce a successful bootstrap")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private func makeClient() -> WenDaTong.PreloginHTTPSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BootstrapHTTPSFixtureProtocol.self]
        return WenDaTong.PreloginHTTPSClient(configuration: configuration)
    }

    private func seed() -> PreloginSeed {
        .init(id: "synthetic-source", baseURL: URL(string: "https://bootstrap-data.example.test/config/")!)
    }

    private func envelope(version: UInt8) -> WenDaTong.PreloginLastGoodEnvelope {
        .init(scopeHash: "synthetic-scope", artifact: Data([version]), keyState: Data([2]), currentPointer: Data([3]), savedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func ownedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-data15-16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor BootstrapHTTPSStartGate {
    static let shared = BootstrapHTTPSStartGate()
    private var expectation: XCTestExpectation?
    func observe(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func signal() { expectation?.fulfill(); expectation = nil }
}

// URLProtocol supplies deterministic HTTP responses to the real URLSession byte stream.
private final class BootstrapHTTPSFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bootstrap-data.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.lastPathComponent == "pending.json" {
            Task { await BootstrapHTTPSStartGate.shared.signal() }
            return
        }
        if url.lastPathComponent == "transport-error.json" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var status = 200
        var headers: [String: String] = [:]
        var responseURL = url
        var body = Data()
        switch url.lastPathComponent {
        case "exact.json": body = Data(repeating: 0x61, count: PreloginStrictJSON.maxBytes)
        case "status.json": status = 503
        case "redirect.json": status = 302; headers["Location"] = url.deletingLastPathComponent().appendingPathComponent("empty.json").absoluteString
        case "response-url.json": responseURL = URL(string: "https://other.example.test/config/empty.json")!
        case "header-too-large.json": headers["Content-Length"] = String(PreloginStrictJSON.maxBytes + 1)
        case "stream-too-large.json": body = Data(repeating: 0x61, count: PreloginStrictJSON.maxBytes + 1)
        default: break
        }
        if request.httpMethod != "GET" || request.value(forHTTPHeaderField: "Accept") != "application/json"
            || request.cachePolicy != .reloadIgnoringLocalCacheData || request.timeoutInterval != 3 {
            status = 418
        }
        let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension RuntimeRoutesP0Tests {
    func testBootstrapDataRecordIORoundTripsRealConfigAndPreservesOldBytesOnEncodingFailure() throws {
        let name = "im4.synthetic.bootstrap-record.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(IMAppBootstrapLastGoodStore.snapshots(appID: "app-one", defaults: defaults).isEmpty)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var bootstrap = try appBootstrapFixture(appID: "app-one", bootstrapHost: "carrier.example.test", revision: 53)
        bootstrap.lifetimeMode = .untilRevoked
        bootstrap.publicationID = "synthetic-publication"
        bootstrap.profileFingerprint = "synthetic-profile"
        // The original codec defaults a published record's missing status to the app status.
        // Keep that legacy rule explicit, then use a normalized input for full-value round trips.
        XCTAssertNil(bootstrap.publicationStatus)
        let legacyPublication = try JSONDecoder().decode(
            RemoteAppBootstrap.self, from: JSONEncoder().encode(bootstrap)
        )
        XCTAssertEqual(legacyPublication.publicationStatus, "enabled")
        bootstrap.publicationStatus = "enabled"
        IMAppBootstrapLastGoodStore.save(bootstrap, appID: "app-one", defaults: defaults, now: savedAt)
        let key = IMAppBootstrapLastGoodRecordStore.storageKey
        let before = try XCTUnwrap(defaults.data(forKey: key))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        let snapshots = IMAppBootstrapLastGoodStore.snapshots(appID: "app-one", defaults: reopened, now: savedAt)
        XCTAssertEqual(snapshots.map(\.bootstrap), [bootstrap])
        XCTAssertEqual(snapshots.first?.bootstrap.lifetimeMode, .untilRevoked)
        XCTAssertEqual(snapshots.first?.bootstrap.routes, bootstrap.routes)
        XCTAssertEqual(snapshots.first?.bootstrap.routingPolicy, bootstrap.routingPolicy)
        let invalid = IM4Data.IMAppBootstrapLastGoodEntry(bootstrap: bootstrap, servingHost: "carrier.example.test", savedAt: .nan)
        IMAppBootstrapLastGoodRecordStore.persist(["synthetic-invalid": invalid], defaults: reopened)
        XCTAssertEqual(reopened.data(forKey: key), before, "Failed encoding must not overwrite the healthy record")
        IMAppBootstrapLastGoodStore.save(bootstrap, appID: "app-one", defaults: reopened, now: savedAt)
        XCTAssertEqual(IMAppBootstrapLastGoodStore.snapshots(appID: "app-one", defaults: defaults, now: savedAt).map(\.bootstrap), [bootstrap])
        // The old entry decoder supplies bootstrapHost when servingHost is absent.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: [String: Any]])
        for entryKey in object.keys { object[entryKey]?.removeValue(forKey: "servingHost") }
        reopened.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        XCTAssertEqual(IMAppBootstrapLastGoodStore.snapshots(appID: "app-one", defaults: defaults, now: savedAt).first?.servingHost, "carrier.example.test")
        let corrupt = Data("damaged-cache".utf8)
        reopened.set(corrupt, forKey: key)
        XCTAssertNil(IMAppBootstrapLastGoodStore.load(appID: "app-one", defaults: defaults, now: savedAt))
        XCTAssertEqual(defaults.data(forKey: key), corrupt, "A read must not delete damaged bytes")
    }
}
// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_END
