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

// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_BEGIN
struct IOSNotificationConversationOpenRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: String
    let messageID: String?
    let channelSeq: Int64?

    init(conversationID: String, messageID: String?, channelSeq: Int64?) {
        id = UUID()
        self.conversationID = conversationID
        self.messageID = messageID
        self.channelSeq = channelSeq
    }

    var jumpTarget: RemoteTenantSearchJumpTarget? {
        guard messageID != nil || channelSeq != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelSeq: channelSeq,
            messageID: messageID
        )
    }
}
// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_END
