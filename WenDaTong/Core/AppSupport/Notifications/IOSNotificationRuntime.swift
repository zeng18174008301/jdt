import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

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
