import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

enum IOSNotificationProcessState: Equatable {
    case foregroundVisible
    case backgroundAlive
    case backgroundSuspended
    case terminated
}

enum IOSNotificationPresentationAction: Equatable {
    case inAppWithSound
    case localSystemNotification
    case systemAPNsNotification
    case cancelExisting
    case ignore
}

enum IOSNotificationPrivacyKind: Equatable {
    case generic
    case voiceCallRequest
    case videoCallRequest
}

enum IOSNotificationAttention: String, Equatable, Sendable {
    case none
    case mention
}

enum IOSNotificationPrivacyCopy {
    static let appTitle = "问达通"
    static let generic = "收到新消息通知"
    static let voiceCallRequest = "收到语音通话请求"
    static let videoCallRequest = "收到视频通话请求"

    static func text(for kind: IOSNotificationPrivacyKind) -> String {
        switch kind {
        case .generic: return generic
        case .voiceCallRequest: return voiceCallRequest
        case .videoCallRequest: return videoCallRequest
        }
    }

    static func authoritativeCallRequest(
        payloadType: String,
        eventType: String,
        callType: String,
        callID: String
    ) -> IOSNotificationPrivacyKind {
        guard payloadType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call",
              eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ringing",
              !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .generic
        }
        switch callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "audio", "voice": return .voiceCallRequest
        case "video": return .videoCallRequest
        default: return .generic
        }
    }
}

@MainActor
protocol IOSNotificationCenterManaging: AnyObject {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: IOSNotificationCenterManaging {}

enum IOSNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var permitsRemoteNotificationRegistration: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}

enum IOSNotificationAuthorizationAction: Equatable, Sendable {
    case requestAuthorization
    case registerRemoteNotifications
    case none
}

enum IOSNotificationAuthorizationPolicy {
    static func action(
        status: IOSNotificationAuthorizationStatus,
        didRequestThisProcess: Bool
    ) -> IOSNotificationAuthorizationAction {
        switch status {
        case .notDetermined:
            return didRequestThisProcess ? .none : .requestAuthorization
        case .authorized, .provisional, .ephemeral:
            return .registerRemoteNotifications
        case .denied, .unknown:
            return .none
        }
    }
}

@MainActor
protocol IOSNotificationAuthorizationManaging: AnyObject {
    func authorizationStatus() async -> IOSNotificationAuthorizationStatus
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
}

@MainActor
final class IOSSystemNotificationAuthorizationManager: IOSNotificationAuthorizationManaging {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> IOSNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class IOSNotificationPermissionCoordinator {
    static let shared = IOSNotificationPermissionCoordinator()

    private let manager: IOSNotificationAuthorizationManaging
    private var didRequestAuthorizationThisProcess = false
    private var isResolving = false
    private(set) var latestStatus: IOSNotificationAuthorizationStatus = .unknown

    init(manager: IOSNotificationAuthorizationManaging = IOSSystemNotificationAuthorizationManager()) {
        self.manager = manager
    }

    func currentStatus() async -> IOSNotificationAuthorizationStatus {
        let status = await manager.authorizationStatus()
        latestStatus = status
        return status
    }

    @discardableResult
    func sceneDidBecomeActive() async -> IOSNotificationAuthorizationStatus {
        await resolvePermissionIfNeeded()
    }

    @discardableResult
    func requestFromUserGestureIfNeeded() async -> IOSNotificationAuthorizationStatus {
        await resolvePermissionIfNeeded()
    }

    private func resolvePermissionIfNeeded() async -> IOSNotificationAuthorizationStatus {
        guard !isResolving else { return latestStatus }
        isResolving = true
        defer { isResolving = false }

        var status = await manager.authorizationStatus()
        latestStatus = status
        switch IOSNotificationAuthorizationPolicy.action(
            status: status,
            didRequestThisProcess: didRequestAuthorizationThisProcess
        ) {
        case .requestAuthorization:
            didRequestAuthorizationThisProcess = true
            _ = await manager.requestAuthorization()
            status = await manager.authorizationStatus()
            latestStatus = status
            if status.permitsRemoteNotificationRegistration {
                manager.registerForRemoteNotifications()
            }
        case .registerRemoteNotifications:
            manager.registerForRemoteNotifications()
        case .none:
            break
        }
        return status
    }
}

@MainActor
final class RTCCallIdleTimerCoordinator {
    static let shared = RTCCallIdleTimerCoordinator()

    private var keepsScreenAwake = false

    func update(activeCallID: String?) {
        let shouldKeepAwake = activeCallID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard keepsScreenAwake != shouldKeepAwake ||
              UIApplication.shared.isIdleTimerDisabled != shouldKeepAwake else { return }
        keepsScreenAwake = shouldKeepAwake
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }

    func reset() {
        update(activeCallID: nil)
    }
}

@MainActor
protocol IOSNotificationLocalIndexStoring: AnyObject {
    func loadRecords() -> [IOSNotificationLocalMetadata]
    func saveRecords(_ records: [IOSNotificationLocalMetadata])
}

@MainActor
final class IOSNotificationUserDefaultsLocalIndexStore: IOSNotificationLocalIndexStoring {
    static let shared = IOSNotificationUserDefaultsLocalIndexStore()

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "im4.ios.localNotification.index.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func loadRecords() -> [IOSNotificationLocalMetadata] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([IOSNotificationLocalMetadata].self, from: data) else {
            return []
        }
        return records
    }

    func saveRecords(_ records: [IOSNotificationLocalMetadata]) {
        let bounded = Array(records.suffix(512))
        if bounded.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct IOSNotificationReadWatermark: Equatable {
    let tenantID: String
    let imUID: String
    let appID: String
    let channelID: String
    let channelType: String
    let lastReadSeq: Int64

    init?(
        tenantID: String,
        imUID: String,
        appID: String,
        channelID: String,
        channelType: String,
        lastReadSeq: Int64
    ) {
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIMUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTenantID.isEmpty,
              !normalizedIMUID.isEmpty,
              !normalizedAppID.isEmpty,
              !normalizedChannelID.isEmpty,
              ["direct", "group", "system"].contains(normalizedChannelType),
              lastReadSeq > 0 else {
            return nil
        }
        self.tenantID = normalizedTenantID
        self.imUID = normalizedIMUID
        self.appID = normalizedAppID
        self.channelID = normalizedChannelID
        self.channelType = normalizedChannelType
        self.lastReadSeq = lastReadSeq
    }
}

struct IOSNotificationLocalMetadata: Codable, Equatable {
    static let schemaVersion = "notification_local.v1"

    let schemaVersion: String
    let requestIdentifier: String
    let notificationID: String
    let aggregateID: String
    let tenantID: String
    let imUID: String
    let appID: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let createdAt: String

    init?(
        notificationID: String,
        aggregateID: String,
        tenantID: String,
        imUID: String,
        appID: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        let normalizedNotificationID = notificationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAggregateID = aggregateID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIMUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedNotificationID.isEmpty,
              !normalizedAggregateID.isEmpty,
              !normalizedTenantID.isEmpty,
              !normalizedIMUID.isEmpty,
              !normalizedAppID.isEmpty,
              !normalizedChannelID.isEmpty,
              ["direct", "group", "system"].contains(normalizedChannelType),
              channelSeq > 0 else {
            return nil
        }
        self.schemaVersion = Self.schemaVersion
        self.notificationID = normalizedNotificationID
        self.aggregateID = normalizedAggregateID
        self.tenantID = normalizedTenantID
        self.imUID = normalizedIMUID
        self.appID = normalizedAppID
        self.channelID = normalizedChannelID
        self.channelType = normalizedChannelType
        self.channelSeq = channelSeq
        self.createdAt = createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        requestIdentifier = Self.deterministicRequestIdentifier(
            tenantID: normalizedTenantID,
            imUID: normalizedIMUID,
            appID: normalizedAppID,
            channelID: normalizedChannelID,
            channelType: normalizedChannelType,
            channelSeq: channelSeq
        )
    }

    static func deterministicRequestIdentifier(
        tenantID: String,
        imUID: String,
        appID: String,
        channelID: String,
        channelType: String,
        channelSeq: Int64
    ) -> String {
        let source = [
            tenantID.trimmingCharacters(in: .whitespacesAndNewlines),
            imUID.trimmingCharacters(in: .whitespacesAndNewlines),
            appID.trimmingCharacters(in: .whitespacesAndNewlines),
            channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            channelID.trimmingCharacters(in: .whitespacesAndNewlines),
            String(channelSeq)
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(source.utf8))
        return "local-msg.v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ watermark: IOSNotificationReadWatermark) -> Bool {
        tenantID == watermark.tenantID
            && imUID == watermark.imUID
            && appID == watermark.appID
            && channelID == watermark.channelID
            && channelType == watermark.channelType
            && channelSeq > 0
            && channelSeq <= watermark.lastReadSeq
    }

    var userInfo: [String: String] {
        [
            "schema_version": schemaVersion,
            "request_identifier": requestIdentifier,
            "notification_id": notificationID,
            "aggregate_id": aggregateID,
            "tenant_id": tenantID,
            "im_uid": imUID,
            "app_id": appID,
            "channel_id": channelID,
            "channel_type": channelType,
            "channel_seq": String(channelSeq),
            "created_at": createdAt
        ]
    }
}

struct IOSNotificationStatePayload: Equatable {
    let notificationID: String
    let aggregateID: String
    let category: String
    let presentation: String
    let scopeKey: String
    let payloadType: String
    let eventType: String
    let callID: String
    let callType: String
    let tenantID: String
    let imUID: String
    let appID: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let targetRef: String
    let attention: IOSNotificationAttention

    var privacyKind: IOSNotificationPrivacyKind {
        let candidate = IOSNotificationPrivacyCopy.authoritativeCallRequest(
            payloadType: payloadType,
            eventType: eventType,
            callType: callType,
            callID: callID
        )
        guard callID == aggregateID else { return .generic }
        switch (category, candidate) {
        case ("voice_call", .voiceCallRequest): return candidate
        case ("video_call", .videoCallRequest): return candidate
        default: return .generic
        }
    }

    var title: String {
        IOSNotificationPrivacyCopy.text(for: privacyKind)
    }

    init?(dictionary: [AnyHashable: Any]) {
        let root = Self.stringDictionary(dictionary)
        let nested = Self.stringDictionary(root["payload"] as? [AnyHashable: Any] ?? [:])
        let values = root.merging(nested) { current, _ in current }
        let schemaVersion = (values["schema_version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // JHT_MOD_BEGIN NOTIFICATION_TAP_LOCAL_SCHEMA_20260917 - 修改开始：允许点击本地通知元数据后恢复会话定位字段
        if schemaVersion == IOSNotificationLocalMetadata.schemaVersion {
            notificationID = Self.firstString(values, keys: ["notification_id", "message_id", "messageID"])
            aggregateID = Self.firstString(values, keys: ["aggregate_id", "conversation_id", "conversationID", "channel_id", "channelID"])
            category = "message"
            presentation = "alert"
            tenantID = Self.firstString(values, keys: ["tenant_id", "tenantId"])
            imUID = Self.firstString(values, keys: ["im_uid", "imUID"])
            appID = Self.firstString(values, keys: ["app_id", "appId"])
            channelID = Self.firstString(values, keys: ["channel_id", "channelID", "conversation_id", "conversationID"])
            channelType = Self.firstString(values, keys: ["channel_type", "channelType"]).lowercased()
            channelSeq = Int64(Self.firstString(values, keys: ["channel_seq", "channelSeq"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            scopeKey = Self.scopeKey(tenantID: tenantID)
            payloadType = ""
            eventType = ""
            callID = ""
            callType = ""
            targetRef = Self.firstString(values, keys: ["target_ref", "targetRef"])
            attention = Self.firstString(values, keys: ["attention"]).lowercased() == "mention" ? .mention : .none
            guard !notificationID.isEmpty,
                  !aggregateID.isEmpty,
                  !scopeKey.isEmpty,
                  !channelID.isEmpty,
                  ["direct", "group", "system"].contains(channelType),
                  channelSeq > 0 else {
                return nil
            }
            return
        }
        // JHT_MOD_END NOTIFICATION_TAP_LOCAL_SCHEMA_20260917 - 修改结束
        guard schemaVersion == "notification_state.v1" else {
            return nil
        }
        notificationID = (values["notification_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aggregateID = (values["aggregate_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        category = ((values["notification_category"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        presentation = ((values["presentation"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        scopeKey = (values["scope_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        payloadType = Self.firstString(values, keys: ["type", "kind"]).lowercased()
        eventType = Self.firstString(values, keys: ["event", "event_type"]).lowercased()
        callID = Self.firstString(values, keys: ["call_id", "callId"])
        callType = Self.firstString(values, keys: ["call_type", "callType"]).lowercased()
        tenantID = Self.firstString(values, keys: ["tenant_id", "tenantId"])
        imUID = Self.firstString(values, keys: ["im_uid", "imUID"])
        appID = Self.firstString(values, keys: ["app_id", "appId"])
        channelID = Self.firstString(values, keys: ["channel_id", "channelID"])
        channelType = Self.firstString(values, keys: ["channel_type", "channelType"]).lowercased()
        channelSeq = Int64(Self.firstString(values, keys: ["channel_seq", "channelSeq"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        targetRef = Self.firstString(values, keys: ["target_ref", "targetRef"])
        attention = Self.firstString(values, keys: ["attention"]).lowercased() == "mention" ? .mention : .none
        guard !notificationID.isEmpty,
              !aggregateID.isEmpty,
              !scopeKey.isEmpty,
              ["message", "voice_call", "video_call"].contains(category),
              ["alert", "cancel"].contains(presentation) else {
            return nil
        }
    }

    private static func firstString(_ values: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = values[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func scopeKey(tenantID: String) -> String {
        let normalized = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var localMetadata: IOSNotificationLocalMetadata? {
        IOSNotificationLocalMetadata(
            notificationID: notificationID,
            aggregateID: aggregateID,
            tenantID: tenantID,
            imUID: imUID,
            appID: appID,
            channelID: channelID,
            channelType: channelType,
            channelSeq: channelSeq
        )
    }

    private static func stringDictionary(_ value: [AnyHashable: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in value {
            result[String(describing: key)] = item
        }
        return result
    }
}

enum IOSNotificationStatePolicy {
    static func action(
        processState: IOSNotificationProcessState,
        payload: IOSNotificationStatePayload
    ) -> IOSNotificationPresentationAction {
        if payload.presentation == "cancel" { return .cancelExisting }
        switch processState {
        case .foregroundVisible: return .inAppWithSound
        case .backgroundAlive: return .localSystemNotification
        case .backgroundSuspended, .terminated: return .systemAPNsNotification
        }
    }
}

enum IOSAPNsEnvironmentPolicy {
    static func resolve(infoValue: String?) -> String {
        #if DEBUG
        let debugFallback = true
        #else
        let debugFallback = false
        #endif
        return resolve(infoValue: infoValue, debugFallback: debugFallback)
    }

    static func resolve(infoValue: String?, debugFallback: Bool) -> String {
        switch infoValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "sandbox": return "sandbox"
        case "production": return "production"
        default: return debugFallback ? "sandbox" : "production"
        }
    }
}

enum IOSNotificationRuntimeEvent: Equatable {
    case standardRegistrationChanged(RemoteDeviceRegistration)
    case standardRegistrationInvalidated(RemoteDeviceRegistration)
    case foregroundNotificationPresented(IOSNotificationStatePayload)
    case notificationOpened(IOSNotificationStatePayload)
}

@MainActor
final class IOSNotificationRuntime {
    static let shared = IOSNotificationRuntime()

    private let notificationCenter: IOSNotificationCenterManaging
    private let localIndexStore: IOSNotificationLocalIndexStoring
    private(set) var standardRegistration: RemoteDeviceRegistration?
    private var acceptedEventIDs: [String] = []
    private var acceptedEventIDSet: Set<String> = []
    private var observers: [UUID: (IOSNotificationRuntimeEvent) -> Bool] = [:]
    private var pendingOpenEvents: [IOSNotificationStatePayload] = []

    init(
        notificationCenter: IOSNotificationCenterManaging = UNUserNotificationCenter.current(),
        localIndexStore: IOSNotificationLocalIndexStoring = IOSNotificationUserDefaultsLocalIndexStore.shared
    ) {
        self.notificationCenter = notificationCenter
        self.localIndexStore = localIndexStore
    }

    static func visibleContent(for privacyKind: IOSNotificationPrivacyKind) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = IOSNotificationPrivacyCopy.appTitle
        content.body = IOSNotificationPrivacyCopy.text(for: privacyKind)
        content.subtitle = ""
        content.threadIdentifier = ""
        content.summaryArgument = ""
        return content
    }

    static func scopeKey(tenantID: String) -> String {
        let normalized = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func observe(_ observer: @escaping (IOSNotificationRuntimeEvent) -> Bool) -> UUID {
        let id = UUID()
        observers[id] = observer
        let pending = pendingOpenEvents
        pendingOpenEvents.removeAll()
        for (index, payload) in pending.enumerated() {
            guard observer(.notificationOpened(payload)) else {
                observers.removeValue(forKey: id)
                pendingOpenEvents.append(contentsOf: pending[index...])
                break
            }
        }
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers.removeValue(forKey: id)
    }

    func updateStandardToken(_ token: Data) {
        guard !token.isEmpty else { return }
        let environment = IOSAPNsEnvironmentPolicy.resolve(
            infoValue: Bundle.main.object(forInfoDictionaryKey: "WXTAPNsEnvironment") as? String
        )
        let next = RemoteDeviceRegistration.apns(
            token: token.map { String(format: "%02x", $0) }.joined(),
            bundleID: Bundle.main.bundleIdentifier ?? "com.jianhuitongqiyetest.app",
            environment: environment
        )
        guard next != standardRegistration else { return }
        standardRegistration = next
        emit(.standardRegistrationChanged(next))
    }

    func invalidateStandardToken() {
        guard let invalidatedRegistration = standardRegistration else { return }
        standardRegistration = nil
        emit(.standardRegistrationInvalidated(invalidatedRegistration))
    }

    func resetAuthenticatedScope() {
        acceptedEventIDs.removeAll()
        acceptedEventIDSet.removeAll()
        pendingOpenEvents.removeAll()
    }

    private func upsertLocalNotificationRecord(_ record: IOSNotificationLocalMetadata?) {
        guard let record else { return }
        var records = localIndexStore.loadRecords()
        records.removeAll {
            $0.requestIdentifier == record.requestIdentifier
                || (!record.notificationID.isEmpty && $0.notificationID == record.notificationID)
        }
        records.append(record)
        localIndexStore.saveRecords(records)
    }

    private func removeLocalNotificationRecords(withIdentifiers identifiers: Set<String>) {
        let normalizedIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedIdentifiers.isEmpty else { return }
        let identifierSet = Set(normalizedIdentifiers)
        let remaining = localIndexStore.loadRecords().filter { record in
            !identifierSet.contains(record.requestIdentifier)
                && !identifierSet.contains(record.notificationID)
                && !identifierSet.contains(record.aggregateID)
        }
        localIndexStore.saveRecords(remaining)
    }

    @discardableResult
    func cancelLocalNotifications(matching watermark: IOSNotificationReadWatermark) -> [String] {
        let records = localIndexStore.loadRecords()
        let matched = records.filter { $0.matches(watermark) }
        let identifiers = Array(Set(matched.flatMap { record in
            [
                record.requestIdentifier,
                record.notificationID
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        })).sorted()
        guard !identifiers.isEmpty else { return [] }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        let matchedRequestIdentifiers = Set(matched.map(\.requestIdentifier))
        localIndexStore.saveRecords(records.filter { record in
            !matchedRequestIdentifiers.contains(record.requestIdentifier)
        })
        return identifiers
    }

    static func normalizedBadgeCount(_ count: Int) -> Int {
        max(0, count)
    }

    func updateApplicationBadge(_ count: Int) {
        let normalized = Self.normalizedBadgeCount(count)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(normalized) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = normalized
        }
    }

    func accept(eventID: String) -> Bool {
        let eventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventID.isEmpty, !acceptedEventIDSet.contains(eventID) else { return false }
        acceptedEventIDs.append(eventID)
        acceptedEventIDSet.insert(eventID)
        while acceptedEventIDs.count > 256 {
            acceptedEventIDSet.remove(acceptedEventIDs.removeFirst())
        }
        return true
    }

    func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        processState: IOSNotificationProcessState
    ) -> IOSNotificationPresentationAction {
        guard let payload = IOSNotificationStatePayload(dictionary: userInfo) else { return .ignore }
        let action = IOSNotificationStatePolicy.action(processState: processState, payload: payload)
        if action == .cancelExisting {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [payload.aggregateID, payload.notificationID])
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [payload.aggregateID, payload.notificationID])
            removeLocalNotificationRecords(withIdentifiers: Set([payload.aggregateID, payload.notificationID]))
            return action
        }
        guard accept(eventID: payload.notificationID) else { return .ignore }
        if action == .inAppWithSound {
            AudioServicesPlayAlertSound(SystemSoundID(1007))
            _ = emit(.foregroundNotificationPresented(payload))
        } else if action == .localSystemNotification {
            let content = Self.visibleContent(for: payload.privacyKind)
            content.sound = .default
            let localMetadata = payload.localMetadata
            var userInfo = [
                "schema_version": "notification_state.v1",
                "notification_id": payload.notificationID,
                "aggregate_id": payload.aggregateID,
                "notification_category": payload.category,
                "presentation": payload.presentation,
                "scope_key": payload.scopeKey,
                "type": payload.payloadType,
                "event": payload.eventType,
                "call_id": payload.callID,
                "call_type": payload.callType
            ]
            if !payload.targetRef.isEmpty {
                userInfo["target_ref"] = payload.targetRef
            }
            if payload.attention == .mention {
                userInfo["attention"] = payload.attention.rawValue
            }
            // JHT_MOD_BEGIN NOTIFICATION_TAP_SCHEMA_PRESERVE_20260917 - 修改开始：保留 state schema，避免本地元数据覆盖点击解析入口
            if let localMetadata {
                userInfo.merge(localMetadata.userInfo) { current, _ in current }
            }
            // JHT_MOD_END NOTIFICATION_TAP_SCHEMA_PRESERVE_20260917 - 修改结束
            content.userInfo = userInfo
            let requestIdentifier = localMetadata?.requestIdentifier ?? payload.aggregateID
            upsertLocalNotificationRecord(localMetadata)
            notificationCenter.add(
                UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil),
                withCompletionHandler: nil
            )
        }
        return action
    }

    @discardableResult
    func handleNotificationResponse(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = IOSNotificationStatePayload(dictionary: userInfo),
              payload.presentation != "cancel" else {
            return false
        }
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [payload.aggregateID, payload.notificationID]
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: [payload.aggregateID, payload.notificationID]
        )
        removeLocalNotificationRecords(withIdentifiers: Set([payload.aggregateID, payload.notificationID]))
        if observers.isEmpty {
            if !pendingOpenEvents.contains(payload) {
                pendingOpenEvents.append(payload)
            }
        } else {
            if !emit(.notificationOpened(payload)) {
                pendingOpenEvents.append(payload)
            }
        }
        return true
    }

    @discardableResult
    private func emit(_ event: IOSNotificationRuntimeEvent) -> Bool {
        var delivered = false
        var staleIDs: [UUID] = []
        for (id, observer) in observers {
            if observer(event) {
                delivered = true
            } else {
                staleIDs.append(id)
            }
        }
        staleIDs.forEach { observers.removeValue(forKey: $0) }
        return delivered
    }

    func presentRealtimeMessage(
        eventID: String,
        backgrounded: Bool,
        localMetadata: IOSNotificationLocalMetadata? = nil
    ) {
        guard accept(eventID: eventID) else { return }
        if !backgrounded {
            AudioServicesPlayAlertSound(SystemSoundID(1007))
            return
        }
        let content = Self.visibleContent(for: .generic)
        content.sound = .default
        if let localMetadata {
            content.userInfo = localMetadata.userInfo
        }
        let requestIdentifier = localMetadata?.requestIdentifier ?? eventID
        upsertLocalNotificationRecord(localMetadata)
        let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
        notificationCenter.add(request, withCompletionHandler: nil)
    }
}

@MainActor
enum VideoCallOrientationPolicy {
    static var isVideoCallPresented = false
}

@MainActor
final class BlueStoneApplicationDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		IMRuntimeColdLaunchLifecycle.shared.beginProcessLaunch()
		UNUserNotificationCenter.current().delegate = self
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: only start the system call layer when this build explicitly enables it.
        if !JHTRuntimeFeatureFlags.disableRTCRuntime,
           SystemCallIntegrationPolicy.usesSystemCallIntegration {
            CallKitPushVoiceCallManager.shared.start()
        }
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
		if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
			_ = IOSNotificationRuntime.shared.handleRemoteNotification(remote, processState: .terminated)
            // JHT_MOD_BEGIN NOTIFICATION_TAP_COLD_LAUNCH_20260917 - 修改开始：冷启动由通知进入时也投递打开会话事件
            if application.applicationState != .background {
                _ = IOSNotificationRuntime.shared.handleNotificationResponse(remote)
            }
            // JHT_MOD_END NOTIFICATION_TAP_COLD_LAUNCH_20260917 - 修改结束
		}
		return true
	}

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        IOSNotificationRuntime.shared.updateStandardToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        IOSNotificationRuntime.shared.invalidateStandardToken()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let state: IOSNotificationProcessState = application.applicationState == .active ? .foregroundVisible : .backgroundAlive
        let action = IOSNotificationRuntime.shared.handleRemoteNotification(userInfo, processState: state)
        completionHandler(action == .ignore ? .noData : .newData)
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if VideoCallOrientationPolicy.isVideoCallPresented || VideoCallScreenshotScenario.requested != nil {
            return .allButUpsideDown
        }
        return .portrait
    }
}

extension BlueStoneApplicationDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let values = sendableNotificationStringValues(notification.request.content.userInfo)
        completionHandler([])
        Task { @MainActor in
            _ = IOSNotificationRuntime.shared.handleRemoteNotification(
                Dictionary(uniqueKeysWithValues: values.map { (AnyHashable($0.key), $0.value as Any) }),
                processState: .foregroundVisible
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let values = sendableNotificationStringValues(response.notification.request.content.userInfo)
        completionHandler()
        Task { @MainActor in
            _ = IOSNotificationRuntime.shared.handleNotificationResponse(
                Dictionary(uniqueKeysWithValues: values.map { (AnyHashable($0.key), $0.value as Any) })
            )
        }
    }

}

private nonisolated func sendableNotificationStringValues(_ userInfo: [AnyHashable: Any]) -> [String: String] {
    var result: [String: String] = [:]
    func append(_ values: [AnyHashable: Any]) {
        for (key, value) in values {
            if let text = value as? String {
                result[String(describing: key)] = text
            } else if let nested = value as? [AnyHashable: Any] {
                append(nested)
            }
        }
    }
    append(userInfo)
    return result
}

enum AccessDiagnosticsOverlayCapability {
    static var isEntryCompiledForCurrentBuild: Bool {
        true
    }

    static func isEntryCompiled(debugBuild _: Bool, internalCapabilityEnabled _: Bool) -> Bool {
        isEntryCompiledForCurrentBuild
    }
}

@main
struct BlueStoneIMApp: App {
    @UIApplicationDelegateAdaptor(BlueStoneApplicationDelegate.self) private var applicationDelegate
    @StateObject private var preloginStartup: PreloginBootstrapStartupGate

    init() {
        StableTabBarAppearance.install()
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        #if targetEnvironment(simulator) && DEBUG
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        SimulatorAccessEnvironment.ensureDefaultSelection()
        #endif
        _preloginStartup = StateObject(
            wrappedValue: PreloginBootstrapStartupGate(
                plan: PreloginBootstrapStartupConfiguration.load()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            PreloginBootstrapStartupView(gate: preloginStartup)
        }
    }
}

private struct PreloginBootstrapStartupView: View {
    @ObservedObject var gate: PreloginBootstrapStartupGate
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch gate.state {
            case let .ready(platformBase):
                BlueStoneRuntimeRoot(trustedPlatformBase: platformBase)
            case .resolving:
                PreloginBootstrapStatusView(
                    title: "正在建立安全连接",
                    message: "正在验证服务入口，请稍候。",
                    showsProgress: true,
                    retry: nil
                )
            case .blocked:
                PreloginBootstrapStatusView(
                    title: "安全连接暂不可用",
                    message: "未能验证可信服务入口。请检查网络后重试。",
                    showsProgress: false,
                    retry: gate.retry
                )
            }
        }
        .task {
            await gate.start()
        }
    }
}

private struct BlueStoneRuntimeRoot: View {
    @StateObject private var state: AppState

    init(trustedPlatformBase: URL?) {
        let api: IMAPIClient
        if let trustedPlatformBase {
            api = IMAPIClient(
                platformBase: trustedPlatformBase,
                trustedPreloginPlatformBase: trustedPlatformBase
            )
        } else {
            api = IMAPIClient()
        }
        _state = StateObject(
            wrappedValue: AppState(
                api: api,
                // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: China-review build keeps RTC calls in-app and avoids CallKit singleton initialization.
                voiceCallSystem: JHTRuntimeFeatureFlags.disableRTCRuntime || !SystemCallIntegrationPolicy.usesSystemCallIntegration
                    ? NoopVoiceCallSystemIntegration()
                    : CallKitPushVoiceCallManager.shared
                // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
            )
        )
    }

    var body: some View {
        RootView()
            .environmentObject(state)
    }
}

private struct PreloginBootstrapStatusView: View {
    let title: String
    let message: String
    let showsProgress: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("正在验证安全服务入口")
            } else if let retry {
                Button("安全重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("重新获取并验证可信服务入口")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private enum StableTabBarAppearance {
    @MainActor
    static func install() {
        let normalItemColor = UIColor(red: 0x66 / 255.0, green: 0x70 / 255.0, blue: 0x85 / 255.0, alpha: 0.90)
        let selectedItemColor = UIColor(red: 0x17 / 255.0, green: 0x20 / 255.0, blue: 0x33 / 255.0, alpha: 1)
        let backgroundColor = UIColor.white.withAlphaComponent(0.82)
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = backgroundColor
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.05)

        configure(
            appearance.stackedLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )
        configure(
            appearance.inlineLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )
        configure(
            appearance.compactInlineLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = selectedItemColor
        tabBar.unselectedItemTintColor = normalItemColor
    }

    @MainActor
    private static func configure(
        _ itemAppearance: UITabBarItemAppearance,
        normalItemColor: UIColor,
        selectedItemColor: UIColor
    ) {
        let normalTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: normalItemColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        let selectedTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: selectedItemColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .bold)
        ]
        itemAppearance.normal.iconColor = normalItemColor
        itemAppearance.normal.titleTextAttributes = normalTitleAttributes
        itemAppearance.selected.iconColor = selectedItemColor
        itemAppearance.selected.titleTextAttributes = selectedTitleAttributes
        itemAppearance.disabled.iconColor = normalItemColor.withAlphaComponent(0.45)
        itemAppearance.disabled.titleTextAttributes = [
            .foregroundColor: normalItemColor.withAlphaComponent(0.45),
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        itemAppearance.normal.badgeBackgroundColor = UIColor(red: 0xFF / 255.0, green: 0x5D / 255.0, blue: 0x73 / 255.0, alpha: 1)
        itemAppearance.selected.badgeBackgroundColor = itemAppearance.normal.badgeBackgroundColor
    }
}

@MainActor
private final class IncomingCallOverlayWindowCoordinator {
    static let shared = IncomingCallOverlayWindowCoordinator()

    private var overlayWindow: UIWindow?
    private weak var boundScene: UIWindowScene?

    func update(call: IncomingVoiceCall?, state: AppState, scenePhase: ScenePhase) {
        let showsCapabilityAlert = state.rtcCapabilityAlertMessage != nil
        guard scenePhase == .active, call != nil || showsCapabilityAlert else {
            hide()
            return
        }
        guard let scene = activeWindowScene() else { return }
        if call != nil {
            // Dismiss the underlying keyboard without clearing its draft. The
            // incoming window must cover a composing page as well as idle pages.
            scene.windows.first(where: { $0.isKeyWindow })?.endEditing(true)
        }
        if boundScene !== scene || overlayWindow == nil {
            hide()
            let window = UIWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.windowLevel = .alert + 1
            let controller = UIHostingController(
                rootView: IncomingCallGlobalWindowView().environmentObject(state)
            )
            controller.view.backgroundColor = .clear
            controller.view.accessibilityViewIsModal = true
            window.rootViewController = controller
            overlayWindow = window
            boundScene = scene
        }
        // One opaque, modal window covers normal pages and already-presented sheets.
        // Keep the existing scene/lifecycle authority; do not compete with call covers.
        overlayWindow?.rootViewController?.view.accessibilityViewIsModal = true
        overlayWindow?.frame = scene.coordinateSpace.bounds
        overlayWindow?.isHidden = false
    }

    func hide() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
        boundScene = nil
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
    }
}

private struct IncomingCallGlobalWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { _ in
            if let message = state.rtcCapabilityAlertMessage {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 20) {
                        Text("通话提示")
                            .font(.headline)
                        Text(message)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("rtc_capability_alert_message")
                        Button("知道了") {
                            state.rtcCapabilityAlertMessage = nil
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("rtc_capability_alert_dismiss")
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .systemBackground)))
                    .padding(.horizontal, 24)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rtc_capability_alert")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let call = state.incomingVoiceCall {
                    IncomingCallScreen(call: call)
                        .id(call.id)
                        .environment(\.avatarImageRouteContext, state.avatarImageRouteContext)
                        .accessibilityIdentifier("incoming_call_global_overlay")
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var accessDiagnostics = AccessDiagnostics.shared

    var body: some View {
        #if DEBUG
        let notificationSettingsScreenshotRequested = ProcessInfo.processInfo.arguments.contains("--notification-settings-screenshot")
        #else
        let notificationSettingsScreenshotRequested = false
        #endif
        return GeometryReader { proxy in
            ZStack {
                if notificationSettingsScreenshotRequested {
                    NavigationStackCompat {
                        NotificationSettingsView()
                    }
                } else if let videoScenario = VideoCallScreenshotScenario.requested {
                    VideoCallScreenshotHost(scenario: videoScenario)
                        .environmentObject(state)
                } else if state.isShowingLaunchSplash {
                    SessionRestoreView()
                        .transition(.opacity)
                } else if let groupLifecycleScenario = state.groupLifecycleScreenshotScenario {
                    GroupLifecycleScreenshotHost(scenario: groupLifecycleScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let groupHistoryScenario = state.groupHistoryVisibilityScreenshotScenario {
                    GroupHistoryVisibilityScreenshotHost(scenario: groupHistoryScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let globalPolicyScenario = state.globalPolicyScreenshotScenario {
                    GlobalPolicyScreenshotHost(scenario: globalPolicyScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let avatarStage4Scenario = state.avatarStage4ScreenshotScenario {
                    AvatarStage4ScreenshotHost(scenario: avatarStage4Scenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if state.isAuthenticated {
                    MainShellView()
                        .allowsHitTesting(!state.isSessionReauthenticationPresented)
                        .accessibilityHidden(state.isSessionReauthenticationPresented)
                        .transition(.move(edge: .trailing).combined(with: .opacity))

                    if let call = state.activeVoiceCall, call.isVideoCall, call.isMinimized {
                        VStack {
                            MinimizedVideoCallBar(session: call)
                            Spacer()
                        }
                        .padding(.top, max(proxy.safeAreaInsets.top, 0))
                        .zIndex(28)
                    }
                } else {
                    AuthRootView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                if VideoCallScreenshotScenario.requested == nil, let toast = state.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(Color.black.opacity(0.78)))
                            .padding(.bottom, 18)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
                }

                if state.isSessionReauthenticationPresented {
                    SessionReauthenticationView()
                        .environmentObject(state)
                        .zIndex(40)
                }

                if let challenge = state.slideCaptchaPrompt {
                    IOSSlideCaptchaVerificationOverlay(challenge: challenge)
                        .environmentObject(state)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(50)
                }

                if accessDiagnostics.isVisible {
                    AccessDebugOverlayHost(
                        diagnostics: accessDiagnostics,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .zIndex(35)
                }

                GlobalBackSwipeInstaller()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                TabBarVisibilityController(isHidden: state.isAuthenticated && state.activeSplashOverlay != nil)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                IOSRiskTelemetryWindowSceneInstaller { windowScene in
                    state.iosRiskTelemetryBind(windowScene: windowScene)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

                if state.isAuthenticated, let splash = state.activeSplashOverlay {
                    SplashOverlay(
                        presentation: splash,
                        remainingSeconds: state.splashOverlayRemainingSeconds,
                        canSkip: state.isSplashOverlaySkippable,
                        onSkip: {
                            state.dismissSplashOverlay()
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)
                    .transition(.opacity)
                    .zIndex(90)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: state.isAuthenticated)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.isRestoringSession)
            .animation(.easeOut(duration: 0.28), value: state.isShowingLaunchSplash)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.incomingVoiceCall)
            .fullScreenCover(item: $state.presentedCallSession) { session in
                if session.isVideoCall {
                    VideoCallScreen(session: session)
                        .environmentObject(state)
                } else {
                    VoiceCallScreen(session: session)
                        .environmentObject(state)
                }
            }
            .fullScreenCover(item: $state.videoCallPreview) { preview in
                VideoCallPreviewScreen(preview: preview)
                    .environmentObject(state)
            }
            .fullScreenCover(item: $state.videoCallTerminalResult) { result in
                VideoCallTerminalResultScreen(result: result)
                    .environmentObject(state)
            }
            .alert(item: forcedAppPolicyAuthPromptBinding) { requirement in
                Alert(
                    title: Text(requirement.promptTitle),
                    message: Text(requirement.promptMessage),
                    dismissButton: .default(Text(requirement.actionTitle)) {
                        state.openForcedAppPolicyAuthDestination(requirement)
                    }
                )
            }
            .fullScreenCover(item: forcedAppPolicyAuthDestinationBinding, onDismiss: {
                state.forcedAppPolicyAuthDestinationDidDismiss()
            }) { requirement in
                ForcedAppPolicyAuthFlowView(requirement: requirement)
                    .environmentObject(state)
            }
            .task {
                RTCCallIdleTimerCoordinator.shared.update(activeCallID: state.activeVoiceCall?.id)
                state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: scenePhase == .active)
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: state.incomingVoiceCall,
                    state: state,
                    scenePhase: scenePhase
                )
                if scenePhase == .active, !shouldSuppressNotificationPermissionRequestForTestScenario {
                    await IOSNotificationPermissionCoordinator.shared.sceneDidBecomeActive()
                }
            }
            .onChangeCompat(of: state.incomingVoiceCall) { _, call in
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: call,
                    state: state,
                    scenePhase: scenePhase
                )
            }
            .onChangeCompat(of: state.activeVoiceCall?.id) { _, activeCallID in
                RTCCallIdleTimerCoordinator.shared.update(activeCallID: activeCallID)
            }
            .onChangeCompat(of: state.rtcCapabilityAlertMessage) { _, _ in
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: state.incomingVoiceCall,
                    state: state,
                    scenePhase: scenePhase
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                state.iosRiskScreenshotDetected()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                // Telemetry is deliberately silent: this callback only refreshes the bound
                // session and queues a content-free fact. Do not add toast, alert, haptics,
                // sound, local notification, or any other screenshot-time user feedback here.
                state.iosRiskScreenshotDetected()
            }
            .onChangeCompat(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    state.appDidEnterForeground()
                    state.handleVideoApplicationWillEnterForeground()
                    if !shouldSuppressNotificationPermissionRequestForTestScenario {
                        Task {
                            await IOSNotificationPermissionCoordinator.shared.sceneDidBecomeActive()
                        }
                    }
                case .inactive:
                    state.appDidBecomeInactive()
                case .background:
                    state.appDidEnterBackground()
                    state.handleVideoApplicationDidEnterBackground()
                @unknown default:
                    state.appDidBecomeInactive()
                }
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: state.incomingVoiceCall,
                    state: state,
                    scenePhase: phase
                )
            }
            .onDisappear {
                IncomingCallOverlayWindowCoordinator.shared.hide()
                RTCCallIdleTimerCoordinator.shared.reset()
            }
            .onReceive(Timer.publish(every: 45, on: .main, in: .common).autoconnect()) { _ in
                guard scenePhase == .active else { return }
                Task {
                    _ = await state.refreshCurrentAppPolicyAndDepartmentRuntime(reason: "active_timer", force: true)
                    await state.refreshCurrentEnterpriseProfile(silent: true)
                }
            }
        }
        .environment(\.avatarImageRouteContext, state.avatarImageRouteContext)
    }

    private var forcedAppPolicyAuthPromptBinding: Binding<AppPolicyForcedAuthRequirement?> {
        Binding(
            get: { state.visibleForcedAppPolicyAuthPrompt },
            set: { state.updateVisibleForcedAppPolicyAuthPrompt($0) }
        )
    }

    private var forcedAppPolicyAuthDestinationBinding: Binding<AppPolicyForcedAuthRequirement?> {
        Binding(
            get: { state.visibleForcedAppPolicyAuthDestination },
            set: { state.updateVisibleForcedAppPolicyAuthDestination($0) }
        )
    }

    private var shouldSuppressNotificationPermissionRequestForTestScenario: Bool {
        #if DEBUG
        if VideoCallScreenshotScenario.requested != nil
            || ProcessInfo.processInfo.arguments.contains("--notification-settings-screenshot")
            || ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("--auth-policy-screenshot=")
                || $0.hasPrefix("--avatar-stage4-screenshot=")
                || $0.hasPrefix("--group-lifecycle-screenshot=")
                || $0.hasPrefix("--group-history-screenshot=")
                || $0.hasPrefix("--global-policy-screenshot=")
                || $0.hasPrefix("--license-quota-screenshot=")
                || $0.hasPrefix("--registration-resolution-screenshot=")
            }) {
            return true
        }
        #endif
        return false
    }
}

private struct LegacyGlobalPolicyScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GlobalPolicyScreenshotScenario

    private var peer: IMUser {
        IMUser(
            id: "im-global-policy-target",
            userID: "user-global-policy-target",
            username: "USERNAME_PLACEHOLDER",
            name: scenario == .friendOn ? "可申请同事" : "受控同事",
            title: "跨部门成员",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: scenario == .friendOn ? "在线" : "",
            lastLoginAt: scenario == .friendOn ? "今天 08:52" : "",
            enterprise: state.currentEnterprise.name,
            avatarSeed: scenario == .friendOn ? 0x14B8A6 : 0x64748B,
            badges: ["非好友"]
        )
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                content
            }
            .navigationTitle("全局策略")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scenario {
        case .memberOff, .memberOn, .adminOff:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    policyHeader
                    groupPermissionSummary
                    GroupListView()
                        .environmentObject(state)
                        .frame(minHeight: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        case .friendOff, .friendOn:
            UserProfileView(user: peer)
                .environmentObject(state)
        case .presence:
            policyHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
        }
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iOS Global Policy Smoke")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("场景：\(scenario.rawValue) · \(state.currentEnterprise.name)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(
                state.visibleGroupMemberCount(state.groups.first?.effectiveMemberCount ?? 0)
                    .map { "群人数：\($0) 人" }
                    ?? "群人数：已隐藏"
            )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.brand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_smoke_header")
    }

    private var groupPermissionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            policyLine(title: "当前角色", value: state.currentEnterprise.role)
            policyLine(title: "建群入口", value: state.canCreateGroupChat ? "显示" : "隐藏")
            policyLine(title: "组织管理", value: state.canManageOrganizationDepartments ? "可管理" : "未开放")
            Text(state.canCreateGroupChat ? "成员/管理员策略允许提交建群。" : "管理员已关闭成员建群，已打开 sheet 时提交也会被 AppState 拦截。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_group_summary")
    }

    private func policyLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
    }
}

private struct LegacyIOSRiskTelemetryWindowSceneInstaller: UIViewRepresentable {
    let onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        SceneProbeView(onWindowSceneChanged: onWindowSceneChanged)
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {
        uiView.onWindowSceneChanged = onWindowSceneChanged
        uiView.publishWindowScene()
    }

    @MainActor
    final class SceneProbeView: UIView {
        var onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

        init(onWindowSceneChanged: @escaping @MainActor (UIWindowScene?) -> Void) {
            self.onWindowSceneChanged = onWindowSceneChanged
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishWindowScene()
        }

        func publishWindowScene() {
            onWindowSceneChanged(window?.windowScene)
        }
    }
}

private struct GlobalPolicyScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GlobalPolicyScreenshotScenario

    private var peer: IMUser {
        IMUser(
            id: "im-global-policy-target",
            userID: "user-global-policy-target",
            username: "USERNAME_PLACEHOLDER",
            name: scenario == .friendOn ? "可申请同事" : "受控同事",
            title: "跨部门成员",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: scenario == .friendOn ? "在线" : "",
            lastLoginAt: scenario == .friendOn ? "今天 08:52" : "",
            enterprise: state.currentEnterprise.name,
            avatarSeed: scenario == .friendOn ? 0x14B8A6 : 0x64748B,
            badges: ["非好友"]
        )
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                content
            }
            .navigationTitle("全局策略")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scenario {
        case .memberOff, .memberOn, .adminOff:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    policyHeader
                    groupPermissionSummary
                    GroupListView()
                        .environmentObject(state)
                        .frame(minHeight: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        case .friendOff, .friendOn:
            UserProfileView(user: peer)
                .environmentObject(state)
        case .presence:
            policyHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
        }
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iOS Global Policy Smoke")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("场景：\(scenario.rawValue) · \(state.currentEnterprise.name)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(
                state.visibleGroupMemberCount(state.groups.first?.effectiveMemberCount ?? 0)
                    .map { "群人数：\($0) 人" }
                    ?? "群人数：已隐藏"
            )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.brand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_smoke_header")
    }

    private var groupPermissionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            policyLine(title: "当前角色", value: state.currentEnterprise.role)
            policyLine(title: "建群入口", value: state.canCreateGroupChat ? "显示" : "隐藏")
            policyLine(title: "组织管理", value: state.canManageOrganizationDepartments ? "可管理" : "未开放")
            Text(state.canCreateGroupChat ? "成员/管理员策略允许提交建群。" : "管理员已关闭成员建群，已打开 sheet 时提交也会被 AppState 拦截。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainCard(radius: 22)
        .accessibilityIdentifier("global_policy_group_summary")
    }

    private func policyLine(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
    }
}

private struct IOSRiskTelemetryWindowSceneInstaller: UIViewRepresentable {
    let onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        SceneProbeView(onWindowSceneChanged: onWindowSceneChanged)
    }

    func updateUIView(_ uiView: SceneProbeView, context: Context) {
        uiView.onWindowSceneChanged = onWindowSceneChanged
        uiView.publishWindowScene()
    }

    @MainActor
    final class SceneProbeView: UIView {
        var onWindowSceneChanged: @MainActor (UIWindowScene?) -> Void

        init(onWindowSceneChanged: @escaping @MainActor (UIWindowScene?) -> Void) {
            self.onWindowSceneChanged = onWindowSceneChanged
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishWindowScene()
        }

        func publishWindowScene() {
            onWindowSceneChanged(window?.windowScene)
        }
    }
}

private struct TabBarVisibilityController: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        Self.setTabBarsHidden(isHidden, from: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        setTabBarsHidden(false, from: uiViewController)
    }

    private static func setTabBarsHidden(_ hidden: Bool, from uiViewController: UIViewController) {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let candidateControllers = scenes
                .flatMap(\.windows)
                .compactMap(\.rootViewController)
                + [uiViewController]
            for controller in candidateControllers {
                findTabBarControllers(in: controller).forEach { tabController in
                    if tabController.tabBar.isHidden != hidden {
                        tabController.tabBar.isHidden = hidden
                    }
                }
            }
        }
    }

    private static func findTabBarControllers(in controller: UIViewController?) -> [UITabBarController] {
        guard let controller else { return [] }
        var result: [UITabBarController] = []
        if let tab = controller as? UITabBarController {
            result.append(tab)
        }
        if let navigation = controller as? UINavigationController {
            result.append(contentsOf: findTabBarControllers(in: navigation.visibleViewController))
        }
        for child in controller.children {
            result.append(contentsOf: findTabBarControllers(in: child))
        }
        if let presented = controller.presentedViewController {
            result.append(contentsOf: findTabBarControllers(in: presented))
        }
        return result
    }
}

private struct SplashOverlay: View {
    let presentation: SplashOverlayPresentation
    let remainingSeconds: Int
    let canSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let screenSize = UIScreen.main.bounds.size
            let topInset = max(proxy.safeAreaInsets.top, 0)
            let bottomInset = max(proxy.safeAreaInsets.bottom, 0)
            let containerSize = CGSize(
                width: max(proxy.size.width, screenSize.width),
                height: max(proxy.size.height + topInset + bottomInset, screenSize.height)
            )
            ZStack(alignment: .topTrailing) {
                splashImageLayer(containerSize: containerSize)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .offset(y: -topInset)
                    .ignoresSafeArea(.all)
                    .allowsHitTesting(false)

                if canSkip {
                    Button(action: onSkip) {
                        HStack(spacing: 6) {
                            Text("跳过")
                            Text("\(max(0, remainingSeconds))s")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.34), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳过启动闪屏")
                    .padding(.top, max(proxy.safeAreaInsets.top + 12, 24))
                    .padding(.trailing, 18)
                    .transition(.opacity)
                }
            }
            .frame(width: max(proxy.size.width, screenSize.width), height: max(proxy.size.height, screenSize.height))
            .clipped()
            .ignoresSafeArea(.all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea(.all))
        .ignoresSafeArea(.all)
        .animation(.easeOut(duration: 0.16), value: canSkip)
    }

    private func splashImageLayer(containerSize: CGSize) -> some View {
        ZStack {
            Color.black

            let image = presentation.image
            let layout = SplashImageCoverLayout.layout(
                imageSize: image.size,
                containerSize: containerSize
            )
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.renderedSize.width, height: layout.renderedSize.height)
                .position(x: containerSize.width / 2, y: containerSize.height / 2)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct AvatarStage4ScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: AvatarStage4ScreenshotScenario

    var body: some View {
        switch scenario {
        case .chatList:
            NavigationStackCompat {
                ConversationListView()
            }
        case .groupChat:
            NavigationStackCompat {
                ChatView(conversationID: "conv-avatar-custom-group")
            }
        case .incomingCall:
            ZStack(alignment: .top) {
                NavigationStackCompat {
                    RTCEntryView()
                }
                if let call = state.incomingVoiceCall {
                    IncomingCallScreen(call: call)
                }
            }
        case .activeCall:
            if let session = state.activeVoiceCall {
                VoiceCallScreen(session: session)
            } else {
                NavigationStackCompat {
                    RTCEntryView()
                }
            }
        case .callRecords:
            NavigationStackCompat {
                RTCEntryView()
            }
        }
    }
}

private struct GroupLifecycleScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GroupLifecycleScreenshotScenario

    private var group: GroupInfo {
        state.group(id: "group-lifecycle-stage4")
            ?? GroupInfo(
                id: "group-lifecycle-stage4",
                name: "群聊退出解散验收群",
                notice: "用于 iOS Stage 4 截图验收。",
                owner: "项目群主",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                memberCount: 0
            )
    }

    var body: some View {
        ZStack {
            GroupDetailView(group: group)
                .environmentObject(state)
            if scenario == .dissolveConfirm {
                VStack {
                    Spacer()
                    GroupDissolveConfirmSheet(
                        group: group,
                        preview: RemoteGroupDissolvePreview(
                            groupID: group.id,
                            memberCount: group.effectiveMemberCount,
                            affectedMembers: group.effectiveMemberCount,
                            confirmationRequired: true,
                            confirmationMode: "button",
                            effects: ["group_hidden", "conversations_removed"]
                        ),
                        isSubmitting: false,
                        onCancel: {},
                        onConfirm: {}
                    )
                    .frame(height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }
                .background(Color.black.opacity(0.08).ignoresSafeArea())
            }
        }
    }
}

private struct ForcedAppPolicyAuthFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let requirement: AppPolicyForcedAuthRequirement

    var body: some View {
        NavigationStackCompat {
            Group {
                switch requirement {
                case .realName:
                    RealNameVerificationFlowView()
                case .phone:
                    PhoneBindingFlowView()
                }
            }
            .environmentObject(state)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                }
            }
        }
    }
}

private struct SessionRestoreView: View {
    var body: some View {
        ZStack {
            Image("LaunchBeach")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .white.opacity(0.06),
                    .white.opacity(0.00),
                    .white.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Image("LoginLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 94, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.16), radius: 22, y: 12)
                    .padding(.top, 132)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MainShellView: View {
    @EnvironmentObject private var state: AppState
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：Tab badge 改为缓存投影，避免 AppState 高频刷新时反复全量统计
    @State private var cachedUnreadTotal = 0
    @State private var cachedPendingContactTaskCount = 0
    @State private var cachedUnreadAnnouncementCount = 0
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    var body: some View {
        MainTabContainerView(
            selection: state.mainTabSelection,
            contactsTitle: state.isDepartmentFeatureEnabled ? "伙伴" : MainTab.contacts.title,
            unreadTotal: cachedUnreadTotal,
            pendingContactTaskCount: cachedPendingContactTaskCount,
            unreadAnnouncementCount: cachedUnreadAnnouncementCount
        )
        .onAppear {
            state.noteMainShellAppeared()
            refreshMainTabBadgeCaches()
            IOSNotificationRuntime.shared.updateApplicationBadge(cachedUnreadTotal)
        }
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：只在对应数据源变化时刷新 badge 投影
        .onReceive(state.conversationStore.$conversations) { _ in
            refreshConversationUnreadBadgeCache()
        }
        .onReceive(state.contactStore.$friendRequests) { _ in
            refreshPendingContactTaskBadgeCache()
        }
        .onReceive(state.contactStore.$inboxItems) { _ in
            refreshUnreadAnnouncementBadgeCache()
        }
        .onChangeCompat(of: cachedUnreadTotal) { _, count in
            IOSNotificationRuntime.shared.updateApplicationBadge(count)
        }
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：集中维护 Tab badge 缓存，降低切换时主线程计算
    private func refreshMainTabBadgeCaches() {
        refreshConversationUnreadBadgeCache()
        refreshPendingContactTaskBadgeCache()
        refreshUnreadAnnouncementBadgeCache()
    }

    private func refreshConversationUnreadBadgeCache() {
        let nextValue = ConversationUnreadBadgeProjection.total(state.conversations)
        guard cachedUnreadTotal != nextValue else { return }
        cachedUnreadTotal = nextValue
    }

    private func refreshPendingContactTaskBadgeCache() {
        let nextValue = state.pendingFriendRequestCount
        guard cachedPendingContactTaskCount != nextValue else { return }
        cachedPendingContactTaskCount = nextValue
    }

    private func refreshUnreadAnnouncementBadgeCache() {
        let nextValue = state.inboxItems.reduce(0) { count, item in
            item.isAnnouncement && !item.isRead ? count + 1 : count
        }
        guard cachedUnreadAnnouncementCount != nextValue else { return }
        cachedUnreadAnnouncementCount = nextValue
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
}

extension MainTab {
    var tabAccessibilityIdentifier: String {
        "main_tab_\(rawValue)"
    }

    func tabAccessibilityLabel(displayTitle: String) -> String {
        "\(displayTitle)标签页"
    }
}

private struct MainTabContainerView: View {
    @ObservedObject var selection: MainTabSelectionState
    let contactsTitle: String
    let unreadTotal: Int
    let pendingContactTaskCount: Int
    let unreadAnnouncementCount: Int
    @State private var loadedTabs: Set<MainTab> = [.chats]

    private var tabAccessibilityDescriptors: [(tab: MainTab, displayTitle: String)] {
        [
            (.chats, MainTab.chats.title),
            (.contacts, contactsTitle),
            (.files, MainTab.files.title),
            (.rtc, MainTab.rtc.title),
            (.me, MainTab.me.title)
        ]
    }

    var body: some View {
        TabView(selection: selection.binding) {
            NavigationStackCompat {
                lazyTabContent(.chats) {
                    ConversationListView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.chats)
            }
            .tabItem {
                tabLabel(.chats, displayTitle: MainTab.chats.title)
            }
            .tag(MainTab.chats)
            .badge(UnreadBadgeFormatter.text(unreadTotal))

            NavigationStackCompat {
                lazyTabContent(.contacts) {
                    ContactsView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.contacts)
            }
            .tabItem {
                tabLabel(.contacts, displayTitle: contactsTitle)
            }
            .tag(MainTab.contacts)
            .badge(UnreadBadgeFormatter.text(pendingContactTaskCount))

            NavigationStackCompat {
                lazyTabContent(.files) {
                    FilesView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.files)
            }
            .tabItem {
                tabLabel(.files, displayTitle: MainTab.files.title)
            }
            .tag(MainTab.files)

            NavigationStackCompat {
                lazyTabContent(.rtc) {
                    RTCEntryView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.rtc)
            }
            .tabItem {
                tabLabel(.rtc, displayTitle: MainTab.rtc.title)
            }
            .tag(MainTab.rtc)

            NavigationStackCompat {
                lazyTabContent(.me) {
                    MeView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.me)
            }
            .tabItem {
                tabLabel(.me, displayTitle: MainTab.me.title)
            }
            .tag(MainTab.me)
            .badge(UnreadBadgeFormatter.text(unreadAnnouncementCount))
        }
        .tint(IMColor.ink)
        .background {
            MainTabAccessibilityInstaller(
                descriptors: tabAccessibilityDescriptors
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            loadedTabs.insert(selection.activeTab)
        }
        .onChangeCompat(of: selection.activeTab) { _, tab in
            loadedTabs.insert(tab)
        }
    }

    private func tabLabel(_ tab: MainTab, displayTitle: String) -> some View {
        Label(displayTitle, systemImage: tab.symbol)
            .accessibilityLabel(tab.tabAccessibilityLabel(displayTitle: displayTitle))
            .accessibilityIdentifier(tab.tabAccessibilityIdentifier)
    }

    @ViewBuilder
    private func lazyTabContent<Content: View>(
        _ tab: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if loadedTabs.contains(tab) || selection.activeTab == tab {
            content()
        } else {
            Color.clear
        }
    }
}

private struct MainTabAccessibilityInstaller: UIViewControllerRepresentable {
    let descriptors: [(tab: MainTab, displayTitle: String)]

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：辅助标识只在描述变化时安装，避免每次刷新递归扫描 TabBar
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let signature = descriptorSignature
        let coordinator = context.coordinator
        guard signature != coordinator.appliedSignature,
              !(coordinator.isUpdatePending && coordinator.pendingSignature == signature) else {
            return
        }
        coordinator.pendingSignature = signature
        coordinator.isUpdatePending = true
        let descriptors = descriptors
        DispatchQueue.main.async {
            coordinator.isUpdatePending = false
            if Self.installAccessibilityDescriptors(descriptors, from: uiViewController) {
                coordinator.appliedSignature = signature
            }
            coordinator.pendingSignature = ""
        }
    }

    private var descriptorSignature: String {
        descriptors.map { descriptor in
            "\(descriptor.tab.rawValue):\(descriptor.displayTitle)"
        }
        .joined(separator: "|")
    }

    final class Coordinator {
        var appliedSignature = ""
        var pendingSignature = ""
        var isUpdatePending = false
    }

    private static func installAccessibilityDescriptors(
        _ descriptors: [(tab: MainTab, displayTitle: String)],
        from uiViewController: UIViewController
    ) -> Bool {
        var didInstall = false
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let candidateControllers = scenes
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
            + [uiViewController]
        for controller in candidateControllers {
            for tabController in Self.findTabBarControllers(in: controller) {
                guard let items = tabController.tabBar.items,
                      items.count == descriptors.count else {
                    continue
                }
                for (item, descriptor) in zip(items, descriptors) {
                    item.accessibilityIdentifier = descriptor.tab.tabAccessibilityIdentifier
                    item.accessibilityLabel = descriptor.tab.tabAccessibilityLabel(
                        displayTitle: descriptor.displayTitle
                    )
                }
                didInstall = true
            }
        }
        return didInstall
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    private static func findTabBarControllers(in controller: UIViewController?) -> [UITabBarController] {
        guard let controller else { return [] }
        var result: [UITabBarController] = []
        if let tab = controller as? UITabBarController {
            result.append(tab)
        }
        if let navigation = controller as? UINavigationController {
            result.append(contentsOf: findTabBarControllers(in: navigation.visibleViewController))
        }
        if let presented = controller.presentedViewController {
            result.append(contentsOf: findTabBarControllers(in: presented))
        }
        for child in controller.children {
            result.append(contentsOf: findTabBarControllers(in: child))
        }
        return result
    }
}
