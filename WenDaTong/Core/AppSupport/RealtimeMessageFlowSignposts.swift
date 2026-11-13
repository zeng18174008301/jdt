import IM4Core
import IM4Domain
import Foundation
import os
import IM4Stores

// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
/// Diagnostic events only: no interval waits, authority, scheduling or business state.
@MainActor
final class RealtimeMessageFlowSignpost {
    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
    struct Installation {
        let realtimeSignposts: [RealtimeMessageFlowSignpost]
        let revision: UInt64
    }
    func memoryDiagnostic() -> MessageMemoryDiagnostic {
        MessageMemoryDiagnostic(onStaged: { self.staged() }, onCommandFinished: { self.commandFinished() },
            onInstalled: { revision, changes in
                Self.installed(Installation(realtimeSignposts: [self], revision: revision), changes: changes).first?.key
            }, onPublicationFinished: { self.publicationFinished() },
            onTimelineObserved: { revision, projected, active in
                self.timelineObserved(revision: revision, projected: projected, sceneActive: active)
            })
    }
    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END
    enum Stage: String, Codable {
        case arrival, transportDuplicate, transportRetired, connectionRejected, admissionRejected
        case notQueued, bufferCancelled, bindingRetired, storeInstalled, noMessageChange
        case projectionConsumed, projectionFiltered, projectionInactive
        case publicationObserved, publicationUnobserved
    }
    struct Event: Codable {
        let correlation: UInt64
        let stage: Stage
        let revision: UInt64?
        let afterPublication: Bool
    }
    private static let signposter = OSSignposter(logger: Logger(
        subsystem: "com.jianhuitongqiyetest.app", category: "realtime-message-flow"))
#if DEBUG
    static var sink: ((Event) -> Void)?
#endif
    private static var enabled: Bool {
#if DEBUG
        return signposter.isEnabled || sink != nil
#else
        return signposter.isEnabled
#endif
    }
    static func arrival(type: String) -> RealtimeMessageFlowSignpost? {
        guard ["message", "message_push", "send_ack"].contains(type), enabled else { return nil }
        let value = RealtimeMessageFlowSignpost()
        value.emit(.arrival)
        return value
    }
    static func retiredTransport(type: String) {
        guard ["message", "message_push", "send_ack", "batch"].contains(type), enabled else { return }
        RealtimeMessageFlowSignpost().finish(.transportRetired)
    }

    private let id = signposter.makeSignpostID()
    // Existing business IDs are used only for in-memory matching, never metadata/output.
    private var messageID: String?
    private var conversationID: String?
    private var handedOff = false
    private var pendingPublications = 0
    private var committedRevision: UInt64?
    private var observed = false
    private var finished = false

    var correlation: UInt64 { id.rawValue } // WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111

    func accept(messageID: String) {
        self.messageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        handedOff = true
    }
    func bind(conversationID: String) { self.conversationID = conversationID }
    func finishIfNotHandedOff() {
        if !handedOff { finish(.notQueued) }
    }
    func finish(_ stage: Stage) {
        guard !finished else { return }
        emit(stage)
        finished = true
    }
    func staged() { pendingPublications += 1 }
    func commandFinished() {
        if pendingPublications == 0, committedRevision == nil { finish(.noMessageChange) }
    }

    /// Called only after the complete frame has become ConversationMemoryCell.current.
    static func installed(_ frame: Installation,
                          changes: [String: ConversationStore.MessageWindowChange]) -> [String: [RealtimeMessageFlowSignpost]] {
        var result: [String: [RealtimeMessageFlowSignpost]] = [:]
        for trace in frame.realtimeSignposts where !trace.finished && trace.committedRevision == nil {
            guard let messageID = trace.messageID, !messageID.isEmpty else { continue }
            guard let conversationID = trace.conversationID, let change = changes[conversationID],
                  let current = change.current.first(where: { $0.id == messageID }),
                  change.previous.first(where: { $0.id == messageID }) != current else { continue }
            trace.committedRevision = frame.revision
            trace.emit(.storeInstalled, revision: frame.revision)
            result[conversationID, default: []].append(trace)
        }
        return result
    }

    /// A mounted timeline consumed this exact commit's projection; this is not a drawn frame.
    func timelineObserved(revision: UInt64, projected: [ChatMessage], sceneActive: Bool) {
        guard committedRevision == revision else { return }
        observed = true
        let stage: Stage = !projected.contains(where: { $0.id == messageID }) ? .projectionFiltered
            : (sceneActive ? .projectionConsumed : .projectionInactive)
        emit(stage, revision: revision)
    }

    /// Synchronous publication has ended, including any reentrant queued commands.
    /// A later SwiftUI observation is a separate event with afterPublication=true.
    func publicationFinished() {
        pendingPublications -= 1
        guard pendingPublications == 0, !finished else { return }
        if let committedRevision {
            emit(observed ? .publicationObserved : .publicationUnobserved, revision: committedRevision)
            finished = true
        } else { finish(.noMessageChange) }
    }

    private func emit(_ stage: Stage, revision: UInt64? = nil) {
        let afterPublication = finished
        Self.signposter.emitEvent("RealtimeMessageFlow", id: id,
            "stage=\(stage.rawValue, privacy: .public) revision=\(revision ?? 0, privacy: .public) after_publication=\(afterPublication, privacy: .public)")
#if DEBUG
        Self.sink?(Event(correlation: id.rawValue, stage: stage, revision: revision, afterPublication: afterPublication))
#endif
    }
}
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

// WDT_IOS1_SDK_GET_V3_20261111_BEGIN — Exact sole Core emitter and HTTP scope.
enum MessageDerivationInstrumentation {
    private static let signposter = OSSignposter(logger: Logger(
        subsystem: "com.jianhuitongqiyetest.app", category: "realtime-message-flow"))
    // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_BEGIN
#if DEBUG
    enum Emission: Equatable, Sendable {
        case sample(MessageDerivationSample)
        case sourceLink(operation: UInt64, sourceCorrelation: UInt64, phase: String, inputRevision: UInt64)
    }
    private static let observerLock = NSLock()
    nonisolated(unsafe) private static var emissionObserver: (@Sendable (Emission) -> Void)?

    /// One process-local test observer. In-flight copied callbacks may finish after removal.
    static func setEmissionObserver(_ observer: (@Sendable (Emission) -> Void)?) {
        observerLock.lock(); emissionObserver = observer; observerLock.unlock()
    }
    private static func observe(_ value: Emission) {
        observerLock.lock(); let observer = emissionObserver; observerLock.unlock()
        observer?(value) // Outside the lock: an observer may remove itself without deadlock.
    }
#endif

    /// Only records a causal edge; never samples time/thread or replays an arrival/decode.
    static func linkToPhysicalSource(operation: UInt64, producerSourceCorrelation: UInt64?) {
        guard let producerSourceCorrelation else { return }
        emitLinks(MessageDerivationTraceContext(operation: operation, sourceCorrelations: [producerSourceCorrelation]),
            phase: "physical_source", inputRevision: 0)
    }

    private static func emitLinks(_ context: MessageDerivationTraceContext, phase: String, inputRevision: UInt64) {
        for correlation in context.sourceCorrelations {
            signposter.emitEvent("MessageDerivationLink", id: OSSignpostID(correlation),
                "operation=\(context.operation, privacy: .public) phase=\(phase, privacy: .public) input_revision=\(inputRevision, privacy: .public)")
#if DEBUG
            observe(.sourceLink(operation: context.operation, sourceCorrelation: correlation,
                phase: phase, inputRevision: inputRevision))
#endif
        }
    }
    // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_END
    static func context(sourceCorrelations: [UInt64] = []) -> MessageDerivationTraceContext {
        MessageDerivationTraceContext(operation: signposter.makeSignpostID().rawValue,
            sourceCorrelations: sourceCorrelations)
    }
    @discardableResult
    static func sample(_ phase: MessageDerivationSample.Phase, context: MessageDerivationTraceContext,
        revision: UInt64, outputRevision: UInt64? = nil, attempt: Int, started: UInt64? = nil) -> MessageDerivationSample {
        let now = DispatchTime.now().uptimeNanoseconds
        let duration = started.map { now &- $0 } ?? 0
        let value = MessageDerivationSample(context: context, phase: phase, inputRevision: revision,
            outputRevision: outputRevision, attempt: attempt, durationNanoseconds: duration,
            onMainThread: Thread.isMainThread, uptimeNanoseconds: now)
        return emit(value)
    }

    /// The execution point supplied these values. Emission never samples the callback thread/clock.
    @discardableResult
    static func emit(_ value: MessageDerivationSample) -> MessageDerivationSample {
        let context = value.context
        signposter.emitEvent("MessageDerivation", id: OSSignpostID(context.operation),
            "phase=\(value.phase.rawValue, privacy: .public) input_revision=\(value.inputRevision, privacy: .public) output_revision=\(value.outputRevision ?? 0, privacy: .public) attempt=\(value.attempt, privacy: .public) duration_ns=\(value.durationNanoseconds, privacy: .public) main=\(value.onMainThread, privacy: .public) uptime_ns=\(value.uptimeNanoseconds, privacy: .public)")
        // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_BEGIN
#if DEBUG
        observe(.sample(value))
#endif
        emitLinks(context, phase: value.phase.rawValue, inputRevision: value.inputRevision)
        // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_END
        return value
    }

    @discardableResult
    static func emit(_ values: [MessageDerivationSample]) -> [MessageDerivationSample] {
        values.forEach { emit($0) }; return values
    }
}

extension AppState {
    /// Metadata travels beside the decoded value; no SDK/business return type or callback changes.
    func traceMessageHTTPRequest<Value: Sendable>(
        _ request: @MainActor () async throws -> Value
    ) async rethrows -> (value: Value, sourceCorrelation: UInt64) {
        let trace = MessageDerivationInstrumentation.context()
        let context: SDKHTTPTraceContext = (trace.operation, { uptime, duration, onMain in
            MessageDerivationInstrumentation.emit(MessageDerivationSample(context: trace, phase: .arrival,
                inputRevision: 0, attempt: 0, durationNanoseconds: duration,
                onMainThread: onMain, uptimeNanoseconds: uptime))
        }, { uptime, duration, onMain in
            MessageDerivationInstrumentation.emit(MessageDerivationSample(context: trace, phase: .decode,
                inputRevision: 0, attempt: 0, durationNanoseconds: duration,
                onMainThread: onMain, uptimeNanoseconds: uptime))
        }, { producerSourceCorrelation in // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_BEGIN
            MessageDerivationInstrumentation.linkToPhysicalSource(operation: trace.operation,
                producerSourceCorrelation: producerSourceCorrelation)
        }) // WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_END
        let value = try await SDKHTTPTrace.$current.withValue(context) { try await request() }
        return (value, context.sourceCorrelation)
    }
}
// WDT_IOS1_SDK_GET_V3_20261111_END

// WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_BEGIN
extension AppState {
    func recordMessageDerivation(_ phase: MessageDerivationSample.Phase, trace: MessageDerivationTraceContext,
        inputRevision: UInt64, outputRevision: UInt64? = nil, started: UInt64? = nil) {
        let value = MessageDerivationInstrumentation.sample(phase, context: trace, revision: inputRevision,
            outputRevision: outputRevision, attempt: 0, started: started)
#if DEBUG
        realtimeComputeRuntime.onDerivation?([value])
#endif
    }

    // WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111: Use the actual key captured by the memory command.
    func derivationMemoryDiagnostic(_ trace: MessageDerivationTraceContext,
        conversationID: @escaping @MainActor () -> String?, inputRevision: UInt64) -> MessageMemoryDiagnostic {
        var installedRevision: UInt64?
        var projectionObserved = false
        return MessageMemoryDiagnostic(onStaged: {}, onCommandFinished: {}, onInstalled: { [weak self] revision, changes in
            guard let self, installedRevision == nil, let id = conversationID(), changes[id] != nil else { return nil }
            installedRevision = revision
            self.recordMessageDerivation(.storeInstalled, trace: trace, inputRevision: inputRevision, outputRevision: revision)
            return id
        }, onPublicationFinished: {}, onTimelineObserved: { [weak self] revision, projected, _ in
            // A mounted timeline can observe while its scene is inactive. Read/visibility authority is separate.
            guard installedRevision == revision, !projected.isEmpty, !projectionObserved else { return }
            projectionObserved = true
            self?.recordMessageDerivation(.projectionObserved, trace: trace,
                inputRevision: inputRevision, outputRevision: revision)
        })
    }
}
// WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_END
