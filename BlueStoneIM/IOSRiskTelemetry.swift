import CryptoKit
import Foundation
import UIKit

enum IOSSceneCaptureTraitState: Equatable, Sendable {
    case active
    case inactive
    case unspecified
}

@MainActor
protocol IOSSceneCaptureSource: AnyObject {
    var sceneIdentifier: String { get }
    var sceneTraitCaptureState: IOSSceneCaptureTraitState { get }
    var boundScreenIsCaptured: Bool { get }
}

@MainActor
enum IOSSceneCaptureResolver {
    static func isCaptured(boundSource: any IOSSceneCaptureSource, supportsSceneCaptureTrait: Bool) -> Bool {
        if supportsSceneCaptureTrait {
            return boundSource.sceneTraitCaptureState == .active
        }
        return boundSource.boundScreenIsCaptured
    }
}

@MainActor
private final class IOSWindowSceneCaptureSource: IOSSceneCaptureSource {
    private weak var windowScene: UIWindowScene?

    init(windowScene: UIWindowScene) {
        self.windowScene = windowScene
    }

    var sceneIdentifier: String {
        windowScene?.session.persistentIdentifier ?? ""
    }

    var sceneTraitCaptureState: IOSSceneCaptureTraitState {
        guard #available(iOS 17.0, *), let windowScene else { return .unspecified }
        switch windowScene.traitCollection.sceneCaptureState {
        case .active: return .active
        case .inactive: return .inactive
        default: return .unspecified
        }
    }

    var boundScreenIsCaptured: Bool {
        windowScene?.screen.isCaptured == true
    }
}

@MainActor
final class IOSSceneCaptureMonitor: NSObject {
    typealias ChangeHandler = @MainActor (Bool) -> Void

    var onChange: ChangeHandler?

    private weak var windowScene: UIWindowScene?
    private var source: IOSWindowSceneCaptureSource?
    private var traitRegistration: AnyObject?
    private var isObservingLegacyScreen = false

    var currentIsCaptured: Bool {
        guard let source else { return false }
        return IOSSceneCaptureResolver.isCaptured(
            boundSource: source,
            supportsSceneCaptureTrait: Self.supportsSceneCaptureTrait
        )
    }

    func bind(windowScene: UIWindowScene?) {
        guard self.windowScene !== windowScene else {
            publishCurrentValue()
            return
        }
        stopObserving()
        self.windowScene = windowScene
        source = windowScene.map(IOSWindowSceneCaptureSource.init)
        guard let windowScene else {
            publishCurrentValue()
            return
        }
        if #available(iOS 17.0, *) {
            traitRegistration = windowScene.registerForTraitChanges(
                [UITraitSceneCaptureState.self],
                target: self,
                action: #selector(sceneCaptureTraitDidChange)
            ) as AnyObject
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundScreenCaptureDidChange(_:)),
                name: UIScreen.capturedDidChangeNotification,
                object: nil
            )
            isObservingLegacyScreen = true
        }
        publishCurrentValue()
    }

    private static var supportsSceneCaptureTrait: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    private func stopObserving() {
        if #available(iOS 17.0, *),
           let windowScene,
           let traitRegistration = traitRegistration as? any UITraitChangeRegistration {
            windowScene.unregisterForTraitChanges(traitRegistration)
        }
        traitRegistration = nil
        if isObservingLegacyScreen {
            NotificationCenter.default.removeObserver(self, name: UIScreen.capturedDidChangeNotification, object: nil)
            isObservingLegacyScreen = false
        }
        source = nil
    }

    private func publishCurrentValue() {
        onChange?(currentIsCaptured)
    }

    @objc private func sceneCaptureTraitDidChange() {
        publishCurrentValue()
    }

    @objc private func boundScreenCaptureDidChange(_ notification: Notification) {
        guard let windowScene else { return }
        if let changedScreen = notification.object as? UIScreen,
           changedScreen !== windowScene.screen {
            return
        }
        publishCurrentValue()
    }
}

struct IOSRiskActivityResource: Codable, Equatable, Sendable {
    let type: String
    let id: String

    init(type: String, id: String = "") {
        self.type = type
        self.id = id
    }
}

struct IOSRiskActivityEvent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let eventType: String
    let source: String
    let platform: String
    let platformVersion: String
    let appVersion: String
    let occurredAt: Date
    let resource: IOSRiskActivityResource?
    let attributes: [String: JSONValue]
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventType = "event_type"
        case source
        case platform
        case platformVersion = "platform_version"
        case appVersion = "app_version"
        case occurredAt = "occurred_at"
        case resource
        case attributes
        case idempotencyKey = "idempotency_key"
    }

    init(
        eventType: String,
        platformVersion: String,
        appVersion: String,
        occurredAt: Date,
        resource: IOSRiskActivityResource? = nil,
        attributes: [String: JSONValue] = [:],
        idempotencyKey: String
    ) {
        schemaVersion = Self.schemaVersion
        self.eventType = eventType
        source = "client"
        platform = "ios"
        self.platformVersion = platformVersion
        self.appVersion = appVersion
        self.occurredAt = occurredAt
        self.resource = resource
        self.attributes = attributes
        self.idempotencyKey = idempotencyKey
    }

    var requestBody: [String: Any] {
        var body: [String: Any] = [
            "schema_version": schemaVersion,
            "event_type": eventType,
            "source": source,
            "platform": platform,
            "platform_version": platformVersion,
            "app_version": appVersion,
            "occurred_at": Self.apiDateString(occurredAt),
            "attributes": attributes.mapValues(\.foundationValue),
            "idempotency_key": idempotencyKey
        ]
        if let resource, !resource.type.isEmpty {
            var resourceBody: [String: Any] = ["type": resource.type]
            if !resource.id.isEmpty {
                resourceBody["id"] = resource.id
            }
            body["resource"] = resourceBody
        }
        return body
    }

    private static func apiDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct IOSRiskActivityItemResult: Decodable, Equatable, Sendable {
    let index: Int
    let status: String
    let eventType: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case index
        case status
        case eventType = "event_type"
        case code
    }

    init(index: Int, status: String, eventType: String = "", code: String = "") {
        self.index = index
        self.status = status
        self.eventType = eventType
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? ""
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
    }
}

struct IOSRiskActivityBatchResult: Decodable, Equatable, Sendable {
    let items: [IOSRiskActivityItemResult]
    let acceptedCount: Int
    let duplicateCount: Int
    let rejectedCount: Int
    let notCollectedCount: Int

    enum CodingKeys: String, CodingKey {
        case items
        case acceptedCount = "accepted_count"
        case duplicateCount = "duplicate_count"
        case rejectedCount = "rejected_count"
        case notCollectedCount = "not_collected_count"
    }

    init(items: [IOSRiskActivityItemResult]) {
        self.items = items
        acceptedCount = items.filter { $0.status == "accepted" }.count
        duplicateCount = items.filter { $0.status == "duplicate" }.count
        rejectedCount = items.filter { $0.status == "rejected" }.count
        notCollectedCount = items.filter { $0.status == "not_collected" }.count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([IOSRiskActivityItemResult].self, forKey: .items) ?? []
        acceptedCount = try container.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
        duplicateCount = try container.decodeIfPresent(Int.self, forKey: .duplicateCount) ?? 0
        rejectedCount = try container.decodeIfPresent(Int.self, forKey: .rejectedCount) ?? 0
        notCollectedCount = try container.decodeIfPresent(Int.self, forKey: .notCollectedCount) ?? 0
    }
}

extension JSONValue {
    fileprivate var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

enum IOSRiskTelemetrySessionGate {
    private struct LocalTokenClaims: Decodable {
        let subject: String
        let tenantID: String
        let appID: String
        let deviceID: String
        let tokenType: String
        let scopes: [String]
        let expiresAt: Int64

        enum CodingKeys: String, CodingKey {
            case subject = "sub"
            case tenantID = "tenant_id"
            case appID = "app_id"
            case deviceID = "device_id"
            case tokenType = "token_type"
            case scopes
            case expiresAt = "exp"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
            tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
            appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
            deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
            tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
            scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
            expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        }
    }

    static func allows(context: IMAPIContext, isAuthenticated: Bool, memberRole: String, now: Date) -> Bool {
        // This unverified claim read is only a local fail-closed prefilter. The tenant API still
        // verifies the signature, binds identity/device/AppId, and resolves subject eligibility.
        guard isAuthenticated, context.hasIMSession else { return false }
        let role = normalizedRole(memberRole)
        guard ["member", "normal", "普通用户", "成员"].contains(role) else { return false }
        guard let token = context.imToken,
              let claims = decodeClaims(token),
              claims.tokenType == "im",
              claims.expiresAt > Int64(now.timeIntervalSince1970),
              claims.subject == context.imUID,
              claims.tenantID == context.tenantID,
              claims.appID == context.appID,
              claims.deviceID == context.deviceID,
              !claims.scopes.contains("im:risk_collection_excluded") else {
            return false
        }
        return true
    }

    private static func normalizedRole(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decodeClaims(_ token: String) -> LocalTokenClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(LocalTokenClaims.self, from: data)
    }
}

@MainActor
final class IOSRiskTelemetryQueueStore {
    static let defaultMaxCount = 500
    static let acceptedClientAge: TimeInterval = 7 * 24 * 60 * 60
    static let acceptedFutureSkew: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let maxCount: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, keyPrefix: String = "im2.ios.riskTelemetry", maxCount: Int = defaultMaxCount) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.maxCount = max(1, maxCount)
    }

    func scopeKey(for context: IMAPIContext) -> String? {
        let values = [context.tenantID ?? "", context.imUID ?? "", context.appID, context.deviceID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }) else { return nil }
        let digest = SHA256.hash(data: Data(values.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load(scope: String, now: Date) -> [IOSRiskActivityEvent] {
        let key = storageKey(scope)
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([IOSRiskActivityEvent].self, from: data) else {
            return []
        }
        let filtered = decoded.filter { event in
            let age = now.timeIntervalSince(event.occurredAt)
            return age <= Self.acceptedClientAge && age >= -Self.acceptedFutureSkew
        }
        if filtered != decoded {
            persist(filtered, scope: scope)
        }
        return filtered
    }

    func append(_ event: IOSRiskActivityEvent, scope: String, now: Date) {
        var events = load(scope: scope, now: now)
        guard !events.contains(where: { $0.idempotencyKey == event.idempotencyKey }) else { return }
        events.append(event)
        if events.count > maxCount {
            events.removeFirst(events.count - maxCount)
        }
        persist(events, scope: scope)
    }

    func remove(idempotencyKeys: Set<String>, scope: String, now: Date) {
        guard !idempotencyKeys.isEmpty else { return }
        let kept = load(scope: scope, now: now).filter { !idempotencyKeys.contains($0.idempotencyKey) }
        persist(kept, scope: scope)
    }

    private func persist(_ events: [IOSRiskActivityEvent], scope: String) {
        let key = storageKey(scope)
        guard !events.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? encoder.encode(events) else { return }
        defaults.set(data, forKey: key)
    }

    private func storageKey(_ scope: String) -> String {
        "\(keyPrefix).\(scope)"
    }
}

@MainActor
final class IOSRiskTelemetryController {
    typealias Submit = @MainActor (IMAPIContext, [IOSRiskActivityEvent]) async throws -> IOSRiskActivityBatchResult

    private struct Session {
        let scope: String
        var context: IMAPIContext
    }

    private let queueStore: IOSRiskTelemetryQueueStore
    private let submit: Submit
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let appVersion: String
    private let platformVersion: String
    private let batchLimit: Int
    private var session: Session?
    private var sceneIsActive = false
    private var foregroundStartedAt: Date?
    private var captureState: Bool?
    private var capabilitiesAnnouncedScopes: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var foregroundCheckpointTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isFlushing = false

    init(
        queueStore: IOSRiskTelemetryQueueStore = IOSRiskTelemetryQueueStore(),
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        platformVersion: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }(),
        batchLimit: Int = 100,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        submit: @escaping Submit
    ) {
        self.queueStore = queueStore
        self.appVersion = Self.stableVersion(appVersion)
        self.platformVersion = Self.stableVersion(platformVersion)
        self.batchLimit = min(max(batchLimit, 1), 100)
        self.now = now
        self.makeUUID = makeUUID
        self.submit = submit
    }

    deinit {
        flushTask?.cancel()
        foregroundCheckpointTask?.cancel()
    }

    func updateSession(
        context: IMAPIContext,
        isAuthenticated: Bool,
        memberRole: String,
        sceneIsActive: Bool,
        captureIsActive: Bool
    ) {
        let currentTime = now()
        guard IOSRiskTelemetrySessionGate.allows(
            context: context,
            isAuthenticated: isAuthenticated,
            memberRole: memberRole,
            now: currentTime
        ), let scope = queueStore.scopeKey(for: context) else {
            endCaptureIfNeeded(at: currentTime)
            endForeground(at: currentTime)
            deactivate()
            return
        }

        if session?.scope != scope {
            endCaptureIfNeeded(at: currentTime)
            endForeground(at: currentTime)
            flushTask?.cancel()
            flushTask = nil
            foregroundCheckpointTask?.cancel()
            foregroundCheckpointTask = nil
            session = Session(scope: scope, context: context)
            captureState = nil
            retryAttempt = 0
            announceCapabilitiesIfNeeded(at: currentTime)
        } else {
            session?.context = context
        }
        if sceneIsActive {
            self.sceneIsActive = true
            recordCaptureState(captureIsActive, occurredAt: currentTime)
            beginForeground(at: currentTime)
            scheduleFlush(delayNanoseconds: 0)
        } else {
            endCaptureIfNeeded(at: currentTime)
            endForeground(at: currentTime)
            self.sceneIsActive = false
        }
    }

    func sceneDidBecomeInactive() {
        sceneDidLeaveActive()
    }

    func sceneDidEnterBackground() {
        sceneDidLeaveActive()
    }

    private func sceneDidLeaveActive() {
        let currentTime = now()
        endCaptureIfNeeded(at: currentTime)
        endForeground(at: currentTime)
        sceneIsActive = false
        captureState = nil
        scheduleFlush(delayNanoseconds: 0)
    }

    func recordScreenshot() {
        guard session != nil, sceneIsActive else { return }
        enqueue(eventType: "screenshot_detected", occurredAt: now())
    }

    func recordCaptureState(_ isCaptured: Bool) {
        recordCaptureState(isCaptured, occurredAt: now())
    }

    func recordClipboardCopy(characterCount: Int, resourceType: String, resourceID: String, channelType: String? = nil, channelID: String? = nil) {
        guard session != nil else { return }
        let resourceType = Self.stableResourceType(resourceType)
        guard !resourceType.isEmpty else { return }
        var attributes: [String: JSONValue] = [
            "character_count_bucket": .string(Self.characterCountBucket(characterCount))
        ]
        if let channelType = Self.stableChannelType(channelType) {
            attributes["channel_type"] = .string(channelType)
        }
        if let channelID = Self.stableID(channelID) {
            attributes["channel_id"] = .string(channelID)
        }
        enqueue(
            eventType: "clipboard_copy",
            occurredAt: now(),
            resource: IOSRiskActivityResource(type: resourceType, id: Self.stableID(resourceID) ?? ""),
            attributes: attributes
        )
    }

    func flushNowForTesting() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    func pendingEventsForTesting() -> [IOSRiskActivityEvent] {
        guard let session else { return [] }
        return queueStore.load(scope: session.scope, now: now())
    }

    private func deactivate() {
        session = nil
        sceneIsActive = false
        captureState = nil
        flushTask?.cancel()
        flushTask = nil
        foregroundCheckpointTask?.cancel()
        foregroundCheckpointTask = nil
        retryAttempt = 0
    }

    private func announceCapabilitiesIfNeeded(at occurredAt: Date) {
        guard let scope = session?.scope, !capabilitiesAnnouncedScopes.contains(scope) else { return }
        capabilitiesAnnouncedScopes.insert(scope)
        enqueue(eventType: "capture_capability", occurredAt: occurredAt, attributes: ["capability": .string("screenshot_detection")])
        enqueue(eventType: "capture_capability", occurredAt: occurredAt, attributes: ["capability": .string("capture_state")])
    }

    private func beginForeground(at occurredAt: Date) {
        guard session != nil, foregroundStartedAt == nil else { return }
        foregroundStartedAt = occurredAt
        scheduleForegroundCheckpoint()
    }

    private func endForeground(at endedAt: Date) {
        foregroundCheckpointTask?.cancel()
        foregroundCheckpointTask = nil
        guard let startedAt = foregroundStartedAt else { return }
        foregroundStartedAt = nil
        enqueueForegroundIntervals(from: startedAt, to: endedAt)
    }

    private func scheduleForegroundCheckpoint() {
        foregroundCheckpointTask?.cancel()
        foregroundCheckpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.sceneIsActive, let startedAt = self.foregroundStartedAt else { return }
            let checkpointAt = self.now()
            self.foregroundStartedAt = checkpointAt
            self.enqueueForegroundIntervals(from: startedAt, to: checkpointAt)
            self.scheduleForegroundCheckpoint()
        }
    }

    private func enqueueForegroundIntervals(from startedAt: Date, to endedAt: Date) {
        guard session != nil, endedAt > startedAt else { return }
        var cursor = startedAt
        while cursor < endedAt {
            let segmentEnd = min(cursor.addingTimeInterval(60 * 60), endedAt)
            let durationMS = max(1, min(Int(segmentEnd.timeIntervalSince(cursor) * 1_000), 3_600_000))
            enqueue(
                eventType: "app_foreground_interval",
                occurredAt: cursor,
                attributes: ["duration_ms": .int(durationMS)]
            )
            cursor = segmentEnd
        }
    }

    private func recordCaptureState(_ isCaptured: Bool, occurredAt: Date) {
        guard session != nil else { return }
        guard sceneIsActive else {
            captureState = nil
            return
        }
        defer { captureState = isCaptured }
        guard captureState != isCaptured else { return }
        if captureState == nil, !isCaptured {
            return
        }
        enqueue(
            eventType: isCaptured ? "capture_state_started" : "capture_state_ended",
            occurredAt: occurredAt,
            attributes: ["capture_kind": .string("unknown")]
        )
    }

    private func endCaptureIfNeeded(at occurredAt: Date) {
        guard session != nil else {
            captureState = nil
            return
        }
        if captureState == true {
            enqueue(
                eventType: "capture_state_ended",
                occurredAt: occurredAt,
                attributes: ["capture_kind": .string("unknown")]
            )
        }
        captureState = nil
    }

    private func enqueue(
        eventType: String,
        occurredAt: Date,
        resource: IOSRiskActivityResource? = nil,
        attributes: [String: JSONValue] = [:]
    ) {
        guard let session else { return }
        let event = IOSRiskActivityEvent(
            eventType: eventType,
            platformVersion: platformVersion,
            appVersion: appVersion,
            occurredAt: occurredAt,
            resource: resource,
            attributes: attributes,
            idempotencyKey: "ios:\(eventType):\(makeUUID().uuidString.lowercased())"
        )
        queueStore.append(event, scope: session.scope, now: now())
        if sceneIsActive {
            scheduleFlush(delayNanoseconds: 250_000_000)
        }
    }

    private func scheduleFlush(delayNanoseconds: UInt64) {
        guard session != nil else { return }
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        guard !isFlushing, let session else { return }
        let events = Array(queueStore.load(scope: session.scope, now: now()).prefix(batchLimit))
        guard !events.isEmpty else {
            retryAttempt = 0
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        do {
            let result = try await submit(session.context, events)
            guard self.session?.scope == session.scope else { return }
            let terminalStatuses = Set(["accepted", "duplicate", "rejected", "not_collected"])
            let terminalKeys = Set(result.items.compactMap { item -> String? in
                guard events.indices.contains(item.index), terminalStatuses.contains(item.status) else { return nil }
                return events[item.index].idempotencyKey
            })
            queueStore.remove(idempotencyKeys: terminalKeys, scope: session.scope, now: now())
            retryAttempt = 0
            if !queueStore.load(scope: session.scope, now: now()).isEmpty, sceneIsActive {
                scheduleFlush(delayNanoseconds: 0)
            }
        } catch {
            guard self.session?.scope == session.scope else { return }
            scheduleRetryIfActive()
        }
    }

    private func scheduleRetryIfActive() {
        guard sceneIsActive else { return }
        let delays: [UInt64] = [2, 5, 15, 60, 300]
        let seconds = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt = min(retryAttempt + 1, delays.count - 1)
        scheduleFlush(delayNanoseconds: seconds * 1_000_000_000)
    }

    private static func stableVersion(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }
        return String(String.UnicodeScalarView(filtered)).prefix(64).description
    }

    private static func stableID(_ value: String?) -> String? {
        let value = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:"))
        guard value.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return value
    }

    private static func stableResourceType(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "message": return "message"
        case "user": return "user"
        default: return ""
        }
    }

    private static func stableChannelType(_ value: String?) -> String? {
        switch (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direct": return "direct"
        case "group": return "group"
        default: return nil
        }
    }

    private static func characterCountBucket(_ count: Int) -> String {
        switch max(count, 1) {
        case 1...20: return "1-20"
        case 21...100: return "21-100"
        case 101...500: return "101-500"
        default: return "501+"
        }
    }
}
