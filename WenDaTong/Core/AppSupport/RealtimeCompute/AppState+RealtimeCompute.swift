// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import Foundation // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension AppState {
    func handleRealtimeEnvelopeSerial(_ envelope: RealtimeEnvelope, diagnostic: RealtimeEnvelopeDiagnosticObservation?,
                                      delivery: RealtimeClient.RealtimeDeliveryContext) async {
        // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_BEGIN
        let flow = diagnostic?.takeMessageFlow() ?? RealtimeMessageFlowSignpost.arrival(type: envelope.type)
        defer { flow?.finishIfNotHandedOff() }
        // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_END
        let admission = captureRealtimeIngestAdmission()
        var handling: RealtimeConnectionDiagnostic.Handling = .appCallbackReturned
        defer { diagnostic?.event.handling = handling }
        guard beginRealtimeEnvelope(envelope, diagnostic: diagnostic) else { handling = .deviceRevoked; return }
        let buffered = ["message", "message_push", "send_ack"].contains(envelope.type) && decodeRealtimeMessage(envelope) != nil
        if buffered {
            (realtimeClient as? RealtimeClient)?.withEnvelopeDiagnostic(diagnostic) {
                dispatchRealtimeEnvelope(envelope, diagnostic: diagnostic, diagnosticHandling: &handling, usesWorker: true, flow: flow)
            }
            if envelope.type == "send_ack" || realtimeIngestBuffer.count >= realtimeIngestFlushLimit {
                await flushPendingRealtimeMessagesSerial()
                if let rejected = admission() { handling = rejected }
            }
            return
        }
        // A control event waits for active admitted work, but only original flush-boundaries drain pending messages.
        if isFlushingRealtimeIngest, let active = realtimeIngestFlushTask { await active.value }
        if requiresRealtimeSerialFlush(envelope) { await flushPendingRealtimeMessagesSerial() }
        guard (realtimeClient as? RealtimeClient)?.isCurrentDelivery(delivery) == true else {
            handling = .staleConnectionRejected; return
        }
        if let rejected = admission() { handling = rejected; return }
        (realtimeClient as? RealtimeClient)?.withEnvelopeDiagnostic(diagnostic) {
            dispatchRealtimeEnvelope(envelope, diagnostic: diagnostic, diagnosticHandling: &handling, usesWorker: true, flow: flow)
        }
    }

    private func requiresRealtimeSerialFlush(_ envelope: RealtimeEnvelope) -> Bool {
        switch envelope.type {
        case "message", "message_push", "send_ack": return true // Reaches here only for the original decode fallback.
        case "message_extra", "message_receipt", "conversation_read", "conversation_update", "resync",
             "group_left", "group_dissolved", "group_member_left", "group_announcement.updated", "group.member.updated",
             "group.settings.updated", "group.owner.transferred", "tenant.policy.updated",
             "certification.assignment.updated", "certification.label.updated",
             "friend_application.created", "friend_application.reviewed", "friend_application.rejected",
             "friend_application.approved", "friend_application.updated", "friend_application.suppressed",
             "friend_application.cancelled", "friend_relation.established", "profile_updated", "profile.updated",
             "blacklist.updated", "blacklist.added", "blacklist.removed", "friend_remark.updated", "contact.remark.updated",
             "rtc.call.ringing", "rtc.call.accepted", "rtc.call.rejected", "rtc.call.canceled", "rtc.call.ended",
             "rtc.call.timed_out", "rtc.call.busy", "rtc_call": return true
        case "notification": return !envelope.isRTCCallNotification
        default: return envelope.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("certification.")
        }
    }

    func computeAndApplyRealtimeWork(_ work: RealtimeMessageIngestBuffer.Work,
                                    admission: RealtimeClient.IncomingAdmission,
                                    isOnlyWork: Bool) async { // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
        let groups = work.groups.map { RealtimeRawMessageGroup(messages: $0.messages, channelID: $0.channelID, channelType: $0.channelType) }
        let trace = MessageDerivationInstrumentation.context(sourceCorrelations: work.groups.flatMap { $0.signposts.map(\.correlation) })
        // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
        let singleRealtimeMessage = isOnlyWork && !work.acknowledgement && groups.count == 1 && groups[0].messages.count == 1
        _ = await deriveAndApplyMessageGroups(groups, trace: trace, diagnostic: work.acknowledgement ? work.diagnostic : nil,
            signposts: work.groups.map(\.signposts), allowsSingleConversationUpdate: singleRealtimeMessage,
            isCurrent: { admission() == nil })
        // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
    }

    @discardableResult
    func applyRemoteMessagesFromAsyncEntry(_ messages: [RemoteMessage], channelID: String, channelType: String,
        windowRetention: ConversationStore.MessageWindowRetention = .preserveLoadedHistory,
        historyBoundary: ConversationStore.HistoryVisibilityBoundary? = nil,
        sequenceCoverageAfterSeq: Int64? = nil, olderHistoryBeforeSeq: Int64? = nil,
        scheduleSequenceRecovery: Bool = true, // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
        sourceCorrelations: [UInt64] = [],
        onApplied: @escaping @MainActor () -> Void = {},
        isCurrent: @MainActor () -> Bool) async -> Bool {
        let options = RemoteMessageDerivationOptions(fromRealtime: false, windowRetention: windowRetention,
            historyBoundary: historyBoundary, sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
            olderHistoryBeforeSeq: olderHistoryBeforeSeq, scheduleSequenceRecovery: scheduleSequenceRecovery) // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
        let group = RealtimeRawMessageGroup(messages: messages, channelID: channelID, channelType: channelType, options: options)
        let scope = remoteDataScopeKey(for: apiContext), epoch = apiContext.sessionEpoch
        return await deriveAndApplyMessageGroups([group], trace: MessageDerivationInstrumentation.context(sourceCorrelations: sourceCorrelations),
            diagnostic: nil, signposts: [[]], onApplied: onApplied, isCurrent: {
                !Task.isCancelled && self.isCurrentRemoteScope(scope) && self.apiContext.sessionEpoch == epoch && isCurrent()
            })
    }

    private func deriveAndApplyMessageGroups(_ groups: [RealtimeRawMessageGroup], trace: MessageDerivationTraceContext,
        diagnostic: RealtimeEnvelopeDiagnosticObservation?, signposts: [[RealtimeMessageFlowSignpost]],
        allowsSingleConversationUpdate: Bool = false, // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
        onApplied: @escaping @MainActor () -> Void = {},
        isCurrent: @MainActor () -> Bool) async -> Bool {
        let queuedAt = DispatchTime.now().uptimeNanoseconds // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
        let token = await realtimeComputeRuntime.enterDerivation()
        defer { realtimeComputeRuntime.leaveDerivation(token) }
        guard isCurrent() else { return false }
#if DEBUG
        let worker = RealtimeComputeWorker(probe: realtimeComputeRuntime.probe)
        realtimeComputeRuntime.fallbackDuringApply = false; realtimeComputeRuntime.fallbackReasons = []
#else
        let worker = RealtimeComputeWorker()
#endif
        var samples = [MessageDerivationInstrumentation.sample(.queued, context: trace,
            revision: conversationStore.memorySnapshot.revision, attempt: 0, started: queuedAt)] // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
        let referenceResult = await worker.tracedReferences(groups, trace: trace)
        let references = referenceResult.0
        samples.append(referenceResult.1)
        var output: RealtimeComputeOutput?
        var stalePlans = 0, attempts = 0
        var acceptedInputRevision: UInt64 = 0
        // A queued/rebased operation keeps the original accepted input. Under repeated contention,
        // keep the preexisting synchronous fallback rather than dropping an admitted ACK.
        while output == nil && attempts < 3 {
            guard isCurrent() else {
                samples.append(MessageDerivationInstrumentation.sample(.rejected, context: trace,
                    revision: conversationStore.memorySnapshot.revision, attempt: attempts))
#if DEBUG
                realtimeComputeRuntime.onDerivation?(samples)
#endif
                return false
            }
            let captureStarted = DispatchTime.now().uptimeNanoseconds
            let contexts = groups.map(captureRealtimeComputeContext)
            let refs = expandedRealtimeReferences(references, contexts: contexts)
            let identity = captureRealtimeMappingIdentity(references: refs, contexts: contexts)
            let stamp = conversationStore.realtimeDerivationStamp
            let revision = conversationStore.memorySnapshot.revision
            attempts += 1
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
            let input = RealtimeComputeInput(groups: groups, contexts: contexts, identity: identity, references: refs,
                conversations: conversationStore.conversationMessageSnapshots(), trace: trace, revision: revision, attempt: attempts)
            samples.append(MessageDerivationInstrumentation.sample(.capture, context: trace,
                revision: revision, attempt: attempts, started: captureStarted))
            // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
            let computed = await worker.compute(input)
            samples += computed.samples
            guard isCurrent() else { continue }
            let validationStarted = DispatchTime.now().uptimeNanoseconds
            let currentContexts = groups.map(captureRealtimeComputeContext)
            let valid = stamp.matches(conversationStore.realtimeDerivationStamp,
                targets: Set(contexts.map(\.targetID)), rtcCalls: computed.relevantRTCKeys)
                && currentContexts == contexts && captureRealtimeMappingIdentity(references: refs, contexts: currentContexts) == identity
            samples.append(MessageDerivationInstrumentation.sample(.validation, context: trace,
                revision: revision, attempt: attempts, started: validationStarted))
            if valid { output = computed; acceptedInputRevision = revision }
            else {
                stalePlans += 1
                samples.append(MessageDerivationInstrumentation.sample(.recompute, context: trace, revision: revision, attempt: attempts))
            }
        }
        guard isCurrent() else {
            samples.append(MessageDerivationInstrumentation.sample(.rejected, context: trace,
                revision: conversationStore.memorySnapshot.revision, attempt: attempts))
#if DEBUG
            realtimeComputeRuntime.onDerivation?(samples)
#endif
            return false
        }
        if output == nil {
            acceptedInputRevision = conversationStore.memorySnapshot.revision
#if DEBUG
            realtimeComputeRuntime.fallbackDuringApply = true
            realtimeComputeRuntime.fallbackReasons = ["contention"]
#endif
        }
        samples.append(MessageDerivationInstrumentation.sample(.ready, context: trace,
            revision: acceptedInputRevision, attempt: attempts))
        let apply = {
            self.conversationStore.performRealtimeAtomicCommand(
                allowsSingleConversationUpdate: allowsSingleConversationUpdate && stalePlans == 0 && output != nil
            ) { // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
                for (index, group) in groups.enumerated() {
                    self.applyRemoteMessages(group.messages, channelID: group.channelID, channelType: group.channelType,
                        fromRealtime: group.options.fromRealtime, realtimeSignposts: signposts[index],
                        preparedRealtime: output?.applications[index], derivationTrace: trace,
                        derivationInputRevision: acceptedInputRevision,
                        windowRetention: group.options.windowRetention, historyBoundary: group.options.historyBoundary,
                        sequenceCoverageAfterSeq: group.options.sequenceCoverageAfterSeq,
                        olderHistoryBeforeSeq: group.options.olderHistoryBeforeSeq,
                        scheduleSequenceRecovery: group.options.scheduleSequenceRecovery) // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
                }
                onApplied()
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        if diagnostic != nil, let client = realtimeClient as? RealtimeClient { client.withEnvelopeDiagnostic(diagnostic, apply) }
        else { apply() }
        samples.append(MessageDerivationInstrumentation.sample(.commit, context: trace,
            revision: acceptedInputRevision, attempt: attempts, started: started))
#if DEBUG
        let first = output?.applications.compactMap { $0 }.first
        realtimeComputeRuntime.onComputed?(RealtimeComputeRuntime.Observation(attempts: attempts, stalePlans: stalePlans,
            fallback: realtimeComputeRuntime.fallbackDuringApply, fallbackReasons: realtimeComputeRuntime.fallbackReasons,
            mappedOnMainThread: first?.mappedOnMainThread ?? realtimeComputeRuntime.fallbackDuringApply,
            mergedOnMainThread: first?.mergedOnMainThread ?? realtimeComputeRuntime.fallbackDuringApply))
        realtimeComputeRuntime.onDerivation?(samples)
#endif
        return true
    }

    private func expandedRealtimeReferences(_ base: RealtimeMappingReferences,
        contexts: [RealtimeRemoteApplyContext]) -> RealtimeMappingReferences {
        var result = base
        for context in contexts {
            result.groups.insert(context.channelID)
            for user in context.participants {
                for raw in [user.id, user.userID, user.username] {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { result.identities.insert(value) }
                }
            }
        }
        return result
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
