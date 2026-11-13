// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation
import IM4Domain
import IM4Data

extension ConversationMessageMergeReducer {
    struct MergeState: Sendable {
        var previousMessages: [ChatMessage]
        var previousMessageByID: [String: ChatMessage]
        var previousMessageBySeq: [Int64: ChatMessage]
        var previousMessageIDs: Set<String>
        var previousMessageSeqs: Set<Int64>
        var previousLocalClientIDs: Set<String>
        var globalRTCAuthorityByCallID: [String: RTCCallRecordAuthority]
        var rtcAuthorityConflictingSequences: Set<Int64>
        var acceptedEntries: [(entry: MappedRemoteMessage, message: ChatMessage)]
        var remoteMessageIDs: Set<String>
        var remoteMessageSeqs: Set<Int64>
        var remoteClientMessageIDs: Set<String>
        var acceptedRTCAuthorityByCallID: [String: RTCCallRecordAuthority]
        var acceptedRTCAuthorityByMessageID: [String: RTCCallRecordAuthority]
        var acceptedRTCAuthorityBySequence: [Int64: RTCCallRecordAuthority]
        var matchedPendingLocalIDs: Set<String>
        var pendingLocalFinalizations: [PendingLocalMessageFinalization]
        var conflictingSequences: Set<Int64>
    }

    func makeState(previous: ConversationMessageSnapshot?, mappedRemoteMessages: [MappedRemoteMessage]) -> MergeState {
        var previousRTCAuthorityByCallID: [String: RTCCallRecordAuthority] = [:]
        var rtcAuthorityConflictingSequences = Set<Int64>()
        let previousMessages = (previous?.messages ?? []).filter { message in
            guard let authority = rtcAuthority(message) else { return true }
            if let existing = previousRTCAuthorityByCallID[authority.callID] {
                if existing != authority, authority.channelSeq > 0 {
                    rtcAuthorityConflictingSequences.insert(authority.channelSeq)
                }
                return false
            }
            previousRTCAuthorityByCallID[authority.callID] = authority
            return true
        }
        var globalRTCAuthorityByCallID: [String: RTCCallRecordAuthority] = [:]
        for conversation in conversationMessageSnapshots() where conversation.id != previous?.id {
            for message in conversation.messages {
                guard let authority = rtcAuthority(message),
                      globalRTCAuthorityByCallID[authority.callID] == nil else { continue }
                globalRTCAuthorityByCallID[authority.callID] = authority
            }
        }
        var previousMessageByID: [String: ChatMessage] = [:]
        var previousMessageBySeq: [Int64: ChatMessage] = [:]
        previousMessages.forEach { previousMessage in
            previousMessageByID[previousMessage.id] = previousMessage
            if previousMessage.channelSeq > 0 {
                previousMessageBySeq[previousMessage.channelSeq] = previousMessage
            }
        }
        let previousMessageIDs = Set(previousMessages.map(\.id))
        let previousMessageSeqs = Set(previousMessages.map(\.channelSeq).filter { $0 > 0 })
        let previousLocalClientIDs = Set(previousMessages.compactMap { message -> String? in
            guard isPendingLocalMessage(message) else { return nil }
            return message.id
        })
        var acceptedEntries: [(entry: MappedRemoteMessage, message: ChatMessage)] = []
        var remoteMessageIDs = Set<String>()
        var remoteMessageSeqs = Set<Int64>()
        var remoteClientMessageIDs = Set<String>()
        var acceptedRTCAuthorityByCallID = previousRTCAuthorityByCallID
        var acceptedRTCAuthorityByMessageID: [String: RTCCallRecordAuthority] = [:]
        var acceptedRTCAuthorityBySequence: [Int64: RTCCallRecordAuthority] = [:]
        for authority in previousRTCAuthorityByCallID.values {
            if !authority.messageID.isEmpty { acceptedRTCAuthorityByMessageID[authority.messageID] = authority }
            if authority.channelSeq > 0 { acceptedRTCAuthorityBySequence[authority.channelSeq] = authority }
        }
        var matchedPendingLocalIDs = Set<String>()
        var pendingLocalFinalizations: [PendingLocalMessageFinalization] = []
        var remoteIDsBySequence: [Int64: Set<String>] = [:]
        for entry in mappedRemoteMessages where entry.remote.channelSeq > 0 {
            let remoteID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteID.isEmpty else { continue }
            remoteIDsBySequence[entry.remote.channelSeq, default: []].insert(remoteID)
        }
        var conflictingSequences = Set(
            remoteIDsBySequence.compactMap { sequence, identifiers in
                identifiers.count > 1 ? sequence : nil
            }
        )

        return MergeState(previousMessages: previousMessages,
            previousMessageByID: previousMessageByID,
            previousMessageBySeq: previousMessageBySeq,
            previousMessageIDs: previousMessageIDs,
            previousMessageSeqs: previousMessageSeqs,
            previousLocalClientIDs: previousLocalClientIDs,
            globalRTCAuthorityByCallID: globalRTCAuthorityByCallID,
            rtcAuthorityConflictingSequences: rtcAuthorityConflictingSequences,
            acceptedEntries: acceptedEntries,
            remoteMessageIDs: remoteMessageIDs,
            remoteMessageSeqs: remoteMessageSeqs,
            remoteClientMessageIDs: remoteClientMessageIDs,
            acceptedRTCAuthorityByCallID: acceptedRTCAuthorityByCallID,
            acceptedRTCAuthorityByMessageID: acceptedRTCAuthorityByMessageID,
            acceptedRTCAuthorityBySequence: acceptedRTCAuthorityBySequence,
            matchedPendingLocalIDs: matchedPendingLocalIDs,
            pendingLocalFinalizations: pendingLocalFinalizations,
            conflictingSequences: conflictingSequences)
    }

    func accept(_ mappedRemoteMessages: [MappedRemoteMessage], readReceiptsEnabled: Bool, state: inout MergeState) {
        for entry in mappedRemoteMessages {
            let remoteMessageID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let authority = rtcAuthority(entry.message)
            // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：复用既有 remote 查找结果，避免重复历史回读再次认领其它 pending
            let previousRemoteMessage = state.previousMessageByID[remoteMessageID]
                ?? (entry.remote.channelSeq > 0 ? state.previousMessageBySeq[entry.remote.channelSeq] : nil)
            // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
            let acceptedRTCIdentity = state.acceptedRTCAuthorityByMessageID[remoteMessageID]
                ?? (entry.remote.channelSeq > 0 ? state.acceptedRTCAuthorityBySequence[entry.remote.channelSeq] : nil)
            if (previousRemoteMessage?.rtcCallRecord != nil || acceptedRTCIdentity != nil), authority == nil {
                if entry.remote.channelSeq > 0 { state.rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let existing = acceptedRTCIdentity, let authority, existing != authority {
                if entry.remote.channelSeq > 0 { state.rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let declaredCallID = entry.remote.payload["call_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !declaredCallID.isEmpty,
               authority == nil,
               (state.acceptedRTCAuthorityByCallID[declaredCallID] != nil || state.globalRTCAuthorityByCallID[declaredCallID] != nil) {
                if entry.remote.channelSeq > 0 { state.rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let authority {
                if state.globalRTCAuthorityByCallID[authority.callID] != nil {
                    if authority.channelSeq > 0 { state.rtcAuthorityConflictingSequences.insert(authority.channelSeq) }
                    continue
                }
                if let existing = state.acceptedRTCAuthorityByCallID[authority.callID] {
                    if existing != authority, authority.channelSeq > 0 {
                        state.rtcAuthorityConflictingSequences.insert(authority.channelSeq)
                    }
                    continue
                }
            }
            if !remoteMessageID.isEmpty, state.remoteMessageIDs.contains(remoteMessageID) {
                continue
            }
            if entry.remote.channelSeq > 0, state.remoteMessageSeqs.contains(entry.remote.channelSeq) {
                continue
            }
            var message = entry.message
            if let previousMessage = previousRemoteMessage {
                let authoritativeSnapshot = entry.remote.payload["sender_snapshot_name"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if authoritativeSnapshot.isEmpty {
                    message.senderName = previousMessage.senderName
                }
                mergeExistingRemoteState(from: previousMessage, into: &message)
            }
            applyRemoteReadSummary(from: entry.remote, to: &message, readReceiptsEnabled: readReceiptsEnabled)
            state.acceptedEntries.append((entry: entry, message: message))
            if let authority = rtcAuthority(message) {
                state.acceptedRTCAuthorityByCallID[authority.callID] = authority
                if !authority.messageID.isEmpty { state.acceptedRTCAuthorityByMessageID[authority.messageID] = authority }
                if authority.channelSeq > 0 { state.acceptedRTCAuthorityBySequence[authority.channelSeq] = authority }
            }
            if let matchedLocalID = entry.matchedLocalID {
                // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：已确认 remote 的重复历史回读只能幂等更新自身，不能触发其它 local 的上传终结
                let remoteAlreadyConfirmed = previousRemoteMessage.map { !isPendingLocalMessage($0) } ?? false
                guard !remoteAlreadyConfirmed || entry.clientMessageIDs.contains(matchedLocalID) else {
                    if !remoteMessageID.isEmpty {
                        state.remoteMessageIDs.insert(remoteMessageID)
                    }
                    if entry.remote.channelSeq > 0 {
                        state.remoteMessageSeqs.insert(entry.remote.channelSeq)
                    }
                    state.remoteClientMessageIDs.formUnion(entry.clientMessageIDs)
                    continue
                }
                // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
                state.matchedPendingLocalIDs.insert(matchedLocalID)
                state.pendingLocalFinalizations.append(PendingLocalMessageFinalization(localID: matchedLocalID, remoteMessage: message))
            }
            if !remoteMessageID.isEmpty {
                state.remoteMessageIDs.insert(remoteMessageID)
            }
            if entry.remote.channelSeq > 0 {
                state.remoteMessageSeqs.insert(entry.remote.channelSeq)
            }
            state.remoteClientMessageIDs.formUnion(entry.clientMessageIDs)
        }
    }
}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
