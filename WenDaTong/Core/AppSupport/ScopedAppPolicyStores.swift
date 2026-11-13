import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

enum LocalHiddenConversationStore {
    private static let storageKey = "local_hidden_conversations_v1"

    static func load(scope: String, defaults: UserDefaults = .standard) -> [String: LocalHiddenConversationRecord] {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return [:] }
        return loadAll(defaults: defaults)[normalizedScope] ?? [:]
    }

    static func save(
        _ records: [String: LocalHiddenConversationRecord],
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return }
        var allRecords = loadAll(defaults: defaults)
        if records.isEmpty {
            allRecords.removeValue(forKey: normalizedScope)
        } else {
            allRecords[normalizedScope] = records
        }
        guard let data = try? JSONEncoder().encode(allRecords) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func hide(
        _ record: LocalHiddenConversationRecord,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        guard !record.channelID.isEmpty else { return }
        var records = load(scope: scope, defaults: defaults)
        records[record.key] = record
        save(records, scope: scope, defaults: defaults)
    }

    static func remove(
        channelID: String,
        channelType: String,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        var records = load(scope: scope, defaults: defaults)
        let key = LocalHiddenConversationRecord.recordKey(channelID: channelID, channelType: channelType)
        records.removeValue(forKey: key)
        save(records, scope: scope, defaults: defaults)
    }

    private static func loadAll(defaults: UserDefaults) -> [String: [String: LocalHiddenConversationRecord]] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: [String: LocalHiddenConversationRecord]].self, from: data) else {
            return [:]
        }
        return records
    }
}

func resolveGroupMemberCountVisibility(
    storedAuthoritative: GroupMemberCountVisibilityRecord?,
    incoming: RemoteTenantClientPolicy
) -> GroupMemberCountVisibilityDecision {
    if !incoming.groupMemberCountPolicyPresent ||
        incoming.groupMemberCountContractVersion < 1 ||
        !incoming.groupMemberCountPolicyAuthoritative {
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming.settingGroupMemberCountVisibility(
                false,
                authoritative: false
            ),
            authoritativeRecordToPersist: nil
        )
    }

    let incomingRecord = GroupMemberCountVisibilityRecord(
        showGroupMemberCount: incoming.showGroupMemberCount,
        generation: incoming.groupMemberCountPolicyGeneration,
        contractVersion: incoming.groupMemberCountContractVersion
    )
    if !incoming.showGroupMemberCount {
        if let storedAuthoritative,
           incoming.groupMemberCountPolicyGeneration < storedAuthoritative.generation {
            return GroupMemberCountVisibilityDecision(
                effectivePolicy: incoming.settingGroupMemberCountVisibility(
                    false,
                    generation: storedAuthoritative.generation,
                    contractVersion: max(
                        incoming.groupMemberCountContractVersion,
                        storedAuthoritative.contractVersion
                    )
                ),
                authoritativeRecordToPersist: nil
            )
        }
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming,
            authoritativeRecordToPersist: incomingRecord
        )
    }

    if let storedAuthoritative,
       (
        storedAuthoritative.showGroupMemberCount
            ? incoming.groupMemberCountPolicyGeneration < storedAuthoritative.generation
            : incoming.groupMemberCountPolicyGeneration <= storedAuthoritative.generation
       ) {
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming.settingGroupMemberCountVisibility(
                false,
                generation: storedAuthoritative.generation,
                contractVersion: max(
                    incoming.groupMemberCountContractVersion,
                    storedAuthoritative.contractVersion
                )
            ),
            authoritativeRecordToPersist: nil
        )
    }

    return GroupMemberCountVisibilityDecision(
        effectivePolicy: incoming,
        authoritativeRecordToPersist: incomingRecord
    )
}

extension RemoteTenantClientPolicy {
    func settingGroupMemberCountVisibility(
        _ visible: Bool,
        generation: Int64? = nil,
        contractVersion: Int? = nil,
        authoritative: Bool? = nil
    ) -> RemoteTenantClientPolicy {
        RemoteTenantClientPolicy(
            allowMemberGroupCreation: allowMemberGroupCreation,
            hideMembershipSystemMessages: hideMembershipSystemMessages,
            clientFriendRequests: clientFriendRequests,
            showGroupMemberCount: visible,
            groupMemberCountPolicyGeneration: generation ?? groupMemberCountPolicyGeneration,
            groupMemberCountContractVersion: contractVersion ?? groupMemberCountContractVersion,
            groupMemberCountPolicyAuthoritative: authoritative ?? groupMemberCountPolicyAuthoritative,
            groupMemberCountPolicyPresent: groupMemberCountPolicyPresent,
            showOnlineStatus: showOnlineStatus,
            showLastLoginTime: showLastLoginTime,
            loginRequireBoundDevice: loginRequireBoundDevice,
            multiDeviceEnabled: multiDeviceEnabled,
            multiDeviceContractVersion: multiDeviceContractVersion,
            multiDevicePolicyAuthoritative: multiDevicePolicyAuthoritative,
            multiDevicePolicyPresent: multiDevicePolicyPresent,
            messageExportEnabled: messageExportEnabled
        )
    }
}

enum IMAppPolicyLastGoodStore {
    private static let storageKey = "im2.ios.lastGoodAppPolicies.v1"

    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
    #if DEBUG
    @TaskLocal static var fixtureSuiteName: String?

    static var defaultsForNewState: UserDefaults {
        guard let suiteName = fixtureSuiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Invalid app policy fixture suite")
        }
        return defaults
    }
    #endif
    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END

    static func save(_ policy: RemoteAppCurrentPolicy, appID rawAppID: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID.isEmpty ? policy.appID : rawAppID)
        guard !appID.isEmpty, policy.isUsable else { return }
        var entries = loadAll(defaults: defaults)
        let ttl = TimeInterval(max(0, policy.cacheTTLSeconds))
        entries[appID] = IMAppPolicyLastGoodEntry(
            appID: appID,
            savedAt: now.timeIntervalSince1970,
            onlineExpiresAt: now.addingTimeInterval(ttl).timeIntervalSince1970,
            // Kept in the persisted v1 shape for downgrade compatibility. It is
            // no longer an eviction boundary: a verified policy remains the
            // last-good authority until an explicit higher revision disables it.
            maxStaleExpiresAt: .greatestFiniteMagnitude,
            policy: policy
        )
        persist(entries, defaults: defaults)
    }

    static func usable(appID rawAppID: String, defaults: UserDefaults = .standard, now: Date = Date()) -> IMAppPolicyLastGoodEntry? {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.isEmpty,
              let entry = loadAll(defaults: defaults)[appID],
              entry.policy.isUsable else {
            return nil
        }
        return entry
    }

    static func clear(appID rawAppID: String, defaults: UserDefaults = .standard) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.isEmpty else { return }
        var entries = loadAll(defaults: defaults)
        entries.removeValue(forKey: appID)
        persist(entries, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func loadAll(defaults: UserDefaults) -> [String: IMAppPolicyLastGoodEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: IMAppPolicyLastGoodEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ entries: [String: IMAppPolicyLastGoodEntry], defaults: UserDefaults) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
