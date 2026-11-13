// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
actor RealtimeComputeWorker {
#if DEBUG
    enum Phase: Sendable { case mapping, merging }
    let probe: (@Sendable (Phase) -> Void)?
    init(probe: (@Sendable (Phase) -> Void)? = nil) { self.probe = probe }
#else
    init() {}
#endif
    func compute(_ input: RealtimeComputeInput) -> RealtimeComputeOutput {
        var state = input.conversations
        var plans: [RealtimeComputeApplication?] = []
        var allRTCKeys: Set<String> = []
        var samples: [MessageDerivationSample] = []
        for (group, context) in zip(input.groups, input.contexts) {
            let result = computeGroup(group, context: context, input: input, state: state)
            plans.append(result.0); state = result.1
            allRTCKeys.formUnion(result.2); samples += result.3
        }
        return RealtimeComputeOutput(applications: plans, relevantRTCKeys: allRTCKeys, samples: samples)
    }
    func tracedReferences(_ groups: [RealtimeRawMessageGroup], trace: MessageDerivationTraceContext)
        -> (RealtimeMappingReferences, MessageDerivationSample) {
        let started = DispatchTime.now().uptimeNanoseconds
        let values = references(groups)
        return (values, MessageDerivationInstrumentation.sample(.references, context: trace,
            revision: 0, attempt: 0, started: started))
    }
    private func computeGroup(_ group: RealtimeRawMessageGroup, context: RealtimeRemoteApplyContext,
        input: RealtimeComputeInput, state initialState: [ConversationMessageSnapshot])
        -> (RealtimeComputeApplication?, [ConversationMessageSnapshot], Set<String>, [MessageDerivationSample]) {
        var state = initialState
        var samples: [MessageDerivationSample] = []
            let reducer = RealtimeConversationReducer(conversations: state)
            let mapper = RealtimeMessageMapper(input: input.identity, reducer: reducer)
            let rawPrevious = state.first { $0.id == context.targetID }
            let previous = reducer.applyingHistoryVisibilityBoundary(context.boundary, to: rawPrevious)
            let visible = group.messages.filter { !mapper.isAnnouncementSystemMessage($0) }
                .filter { mapper.isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: context.boundary) }
            if visible.isEmpty || context.hiddenThroughSeq.map({ hidden in
                let latest = visible.map(\.channelSeq).max() ?? 0
                return latest <= hidden || latest <= 0
            }) == true { return (nil, state, [], samples) }
#if DEBUG
            probe?(.mapping)
#endif
            let mappingStarted = DispatchTime.now().uptimeNanoseconds
            let old = previous?.messages ?? []
            let olderFastPath = group.options.olderHistoryBeforeSeq.map { before in
                before > 1 && visible.allSatisfy { $0.channelSeq > 0 && $0.channelSeq < before }
            } ?? false
            let localIDs: Set<String> = olderFastPath ? [] : Set(old.filter(mapper.isPendingLocalMessage).map(\.id))
            let pending = olderFastPath ? [] : old.filter(mapper.isPendingLocalMessage)
            let rtcIDs = Set(visible.filter { $0.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" }
                .map { $0.messageID.trimmingCharacters(in: .whitespacesAndNewlines) }).union(old.filter { $0.rtcCallRecord != nil }.map(\.id))
            var usedLocal: Set<String> = [], remoteIDs: Set<String> = []
            var mapped: [ConversationStore.MappedRemoteMessage] = []
            var sideEffects: [RemoteMessage] = []
            for remote in visible {
                let id = remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, remoteIDs.contains(id), !rtcIDs.contains(id) { continue }
                sideEffects.append(remote)
                let clients = olderFastPath ? [] : mapper.remoteClientMessageIdentifiers(remote)
                let matched = olderFastPath ? nil : mapper.matchedPendingLocalMessageID(for: remote, pendingLocals: pending, usedLocalIDs: usedLocal)
                if let matched { usedLocal.insert(matched) }
                var message = mapper.chatMessage(from: remote, participants: context.participants,
                    forceOutgoing: clients.contains { localIDs.contains($0) } || matched != nil)
                if context.kind == .group, !input.identity.showsGroupMemberCount {
                    message.readCount = nil; message.unreadCount = nil
                    if message.kind == .system { message.text = textRemovingGroupMemberTotals(message.text) }
                }
                mapped.append(ConversationStore.MappedRemoteMessage(remote: remote, message: message,
                    clientMessageIDs: Set(clients), isRemoteFromCurrentUser: mapper.isRemoteMessageFromCurrentUser(remote), matchedLocalID: matched))
                if !id.isEmpty { remoteIDs.insert(id) }
            }
            if let trace = input.trace {
                samples.append(MessageDerivationInstrumentation.sample(.mapping, context: trace,
                    revision: input.revision, attempt: input.attempt, started: mappingStarted))
            }
            let mergingStarted = DispatchTime.now().uptimeNanoseconds
#if DEBUG
            let mappedOnMain = Thread.isMainThread
            probe?(.merging)
#endif
            let merged = reducer.mergeMappedRemoteMessages(previous: previous, mappedRemoteMessages: mapped,
                readReceiptsEnabled: input.identity.readReceiptsEnabled, fromRealtime: group.options.fromRealtime,
                windowRetention: group.options.windowRetention, sequenceCoverageAfterSeq: group.options.sequenceCoverageAfterSeq,
                olderHistoryBeforeSeq: olderFastPath ? group.options.olderHistoryBeforeSeq : nil,
                coveredChannelSeqs: group.messages.filter { mapper.isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: context.boundary) }.map(\.channelSeq),
                effectiveReadSeq: context.effectiveReadSeq)
            if let trace = input.trace {
                samples.append(MessageDerivationInstrumentation.sample(.merging, context: trace,
                    revision: input.revision, attempt: input.attempt, started: mergingStarted))
            }
#if DEBUG
            let mergedOnMain = Thread.isMainThread // Merge includes the actual original timeline sort synchronously.
#endif
            let orderingStarted = DispatchTime.now().uptimeNanoseconds
            let rtcKeys = Set(old.compactMap { $0.rtcCallRecord?.callID })
                .union(mapped.compactMap { $0.message.rtcCallRecord?.callID })
                .union(mapped.compactMap { $0.remote.payload["call_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let global = reducer.globalRTCAuthorities(excluding: previous?.id, keys: rtcKeys)

            let applied = merged.latestMessage.map { latest in
                reducer.makeMergedRemoteMessagesConversation(channelID: group.channelID, kind: context.kind, previous: previous,
                    title: context.title, subtitle: previous?.subtitle ?? context.kind.rawValue, participants: context.participants,
                    messages: merged.messages, latestMessage: latest, incomingRealtimeMessages: merged.incomingRealtimeMessages,
                    latestKnownSeq: merged.latestKnownSeq, messageCoveredThroughSeq: merged.messageCoveredThroughSeq,
                    messageCoverageRequiresRecovery: merged.messageCoverageRequiresRecovery, fromRealtime: group.options.fromRealtime,
                    isActiveRealtimeConversation: context.active, canAutoReadActiveRealtimeConversation: context.canAutoRead,
                    memberCount: context.memberCount, accentHex: context.accentHex, avatarURL: context.avatarURL,
                    avatarVersion: context.avatarVersion, avatarUpdatedAt: context.avatarUpdatedAt,
                    effectiveReadSeq: context.effectiveReadSeq, historyBoundary: context.boundary)
            }
#if DEBUG
            let plan = RealtimeComputeApplication(group: group, context: context, expectedRawPrevious: rawPrevious, expectedPrevious: previous,
                visibleMessages: visible, changesState: applied?.conversation != rawPrevious,
                identity: input.identity, references: input.references, mapped: mapped, expectedGlobalRTC: global, relevantRTCKeys: rtcKeys,
                mappingSideEffects: sideEffects, merge: merged, applied: applied,
                mappedOnMainThread: mappedOnMain, mergedOnMainThread: mergedOnMain)
#else
            let plan = RealtimeComputeApplication(group: group, context: context, expectedRawPrevious: rawPrevious, expectedPrevious: previous,
                visibleMessages: visible, changesState: applied?.conversation != rawPrevious,
                identity: input.identity, references: input.references, mapped: mapped, expectedGlobalRTC: global, relevantRTCKeys: rtcKeys,
                mappingSideEffects: sideEffects, merge: merged, applied: applied)
#endif
            if let value = applied?.conversation {
                if let i = state.firstIndex(where: { $0.id == previous?.id || $0.id == value.id || $0.id == group.channelID }) { state[i] = value }
                else { state.insert(value, at: 0) }
                state.sort(by: reducer.conversationListPrecedes)
                // The original per-group Main tail scrubs all group windows before the next group.
                if context.kind == .group, !input.identity.showsGroupMemberCount {
                    state = state.map { $0.scrubbingGroupMemberTotals() }
                }
            }
            if let trace = input.trace {
                samples.append(MessageDerivationInstrumentation.sample(.ordering, context: trace,
                    revision: input.revision, attempt: input.attempt, started: orderingStarted))
            }
            return (plan, state, rtcKeys, samples)
    }

}

extension RealtimeConversationReducer {
    func globalRTCAuthorities(excluding target: String?, keys: Set<String>) -> [String: RTCCallRecordMessageDeduplicator.Authority] {
        guard !keys.isEmpty else { return [:] }
        var result: [String: RTCCallRecordMessageDeduplicator.Authority] = [:]
        for conversation in conversations where conversation.id != target {
            for message in conversation.messages {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message), keys.contains(authority.callID),
                      result[authority.callID] == nil else { continue }
                result[authority.callID] = authority
            }
        }
        return result
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
