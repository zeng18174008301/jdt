// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension AppState {
    func captureRealtimeComputeContext(_ group: RealtimeRawMessageGroup) -> RealtimeRemoteApplyContext {
        let kind = conversationKind(from: group.channelType, channelID: group.channelID)
        let lookup = makeConversationUserLookup()
        let index = conversationStore.conversations.firstIndex { $0.id == group.channelID }
            ?? conversationStore.conversationMessageSnapshots().firstIndex { remoteChannelID(for: $0, lookup: lookup) == group.channelID }
        let raw = index.map { conversationStore.conversationMessageSnapshot(at: $0) }
        let boundary = kind == .group ? (group.options.historyBoundary ?? conversationStore.historyBoundary(for: raw)) : nil
        let previous = raw // Visibility changes summary/unread only; context identity/read/title inputs are unchanged.
        let participants = conversationParticipants(channelID: group.channelID, kind: kind, previous: previous, lookup: lookup)
        let channel = normalizedRemoteChannelID(group.channelID, channelType: group.channelType)
        let type = normalizedReadWatermarkChannelType(channelID: channel, channelType: group.channelType)
        let key = conversationReadStateKey(channelID: channel, channelType: type)
        let scope = currentReadWatermarkScope(channelID: channel, channelType: type)
        let effectiveRead = max(previous?.lastReadSeq ?? 0, conversationStore.effectiveReadSeq(readStateKey: key, scope: scope))
        let groupInfo = kind == .group ? groups.first { $0.id == group.channelID } : nil
        let remoteScope = remoteDataScopeKey(for: apiContext)
        let hidden = apiContext.hasIMSession ? locallyHiddenRecord(channelID: group.channelID, channelType: group.channelType,
            records: LocalHiddenConversationStore.load(scope: remoteScope), lookup: lookup)?.hiddenThroughSeq : nil
        return RealtimeRemoteApplyContext(channelID: group.channelID, channelType: group.channelType,
            targetID: raw?.id ?? (kind == .system ? "system_notification" : group.channelID), kind: kind,
            boundary: boundary, participants: participants, effectiveReadSeq: effectiveRead,
            title: conversationTitle(channelID: group.channelID, kind: kind, previous: previous, lookup: lookup),
            memberCount: resolvedConversationMemberCount(kind: kind, channelID: group.channelID, previous: previous, participants: participants),
            accentHex: stableSeed(group.channelID), avatarURL: groupInfo?.avatarURL ?? "", avatarVersion: groupInfo?.avatarVersion ?? "",
            avatarUpdatedAt: groupInfo?.avatarUpdatedAt ?? "", active: activeRealtimeConversationID == (previous?.id ?? group.channelID)
                || activeRealtimeConversationID == group.channelID,
            canAutoRead: conversationStore.canAutoReadActiveRealtimeConversation(previousConversationID: previous?.id, channelID: group.channelID),
            hiddenThroughSeq: hidden)
    }

    func captureRealtimeMappingIdentity(references: RealtimeMappingReferences,
        contexts: [RealtimeRemoteApplyContext]) -> RealtimeMappingIdentity {
        func ids(_ user: IMUser) -> [String] {
            [user.id, user.userID, user.username].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var relevant = references.identities.union(currentUserIdentitySet())
        for context in contexts { for user in context.participants { relevant.formUnion(ids(user)) } }
        let selectedContacts = contacts.filter { references.requiresContactNameLookup || !Set(ids($0)).isDisjoint(with: relevant) }
        let selectedMembers = groups.flatMap(\.members).filter { references.requiresContactNameLookup || !Set(ids($0)).isDisjoint(with: relevant) }
        for user in selectedContacts + selectedMembers { relevant.formUnion(ids(user)) }
        let selectedRemarks = contactRemarks.filter { relevant.contains($0.key) }
        var calendar = Calendar.current
        let zone = TimeZone.current; calendar.timeZone = zone
        let clock = RealtimeDisplayClock(calendar: calendar, timeZone: zone, day: calendar.startOfDay(for: Date()))
        let groupIDs = references.groups.union(contexts.map(\.channelID))
        return RealtimeMappingIdentity(currentUser: currentUser, currentIdentities: currentUserIdentitySet(),
            senderIdentities: currentMessageSenderIdentitySet(), outgoingSenderID: localOutgoingMessageSenderID(),
            contacts: selectedContacts, directoryUsers: selectedMembers, remarks: selectedRemarks,
            groups: groups.filter { groupIDs.contains($0.id) }.map { RealtimeMappingIdentity.GroupName(id: $0.id, name: $0.name) },
            resolvedAvatarURLs: Dictionary(uniqueKeysWithValues: references.avatars.map { ($0, resolveTenantAssetURL($0)) }),
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled, showsGroupMemberCount: shouldShowGroupMemberCount, clock: clock)
    }

    func realtimePreparedApplicationIsCurrent(_ plan: RealtimeComputeApplication, rawPrevious: ConversationMessageSnapshot?) -> Bool {
        guard plan.expectedRawPrevious == rawPrevious else { return rejectPreparedRealtime("window") }
        let context = captureRealtimeComputeContext(plan.group)
        guard context == plan.context else { return rejectPreparedRealtime("context") }
        guard captureRealtimeMappingIdentity(references: plan.references, contexts: [context]) == plan.identity else { return rejectPreparedRealtime("identity") }
        guard conversationStore.realtimeGlobalRTCAuthorities(excluding: plan.expectedPrevious?.id, keys: plan.relevantRTCKeys) == plan.expectedGlobalRTC else { return rejectPreparedRealtime("rtc") }
        return true
    }
    private func rejectPreparedRealtime(_ reason: String) -> Bool {
#if DEBUG
        realtimeComputeRuntime.fallbackReasons.append(reason)
#endif
        return false
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
