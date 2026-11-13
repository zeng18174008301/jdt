// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation

public struct MessageDerivationTraceContext: Equatable, Sendable, Codable {
    public let operation: UInt64
    public let sourceCorrelations: [UInt64]
    public init(operation: UInt64, sourceCorrelations: [UInt64] = []) {
        self.operation = operation; self.sourceCorrelations = sourceCorrelations
    }
}

public struct MessageDerivationSample: Equatable, Sendable, Codable {
    public enum Phase: String, Sendable, Codable {
        case arrival, decode, queued, references, capture, validation, mapping, merging, ordering, ready, recompute, rejected, commit, storeInstalled, projectionObserved
    }
    public let context: MessageDerivationTraceContext
    public let phase: Phase
    public let inputRevision: UInt64
    public let outputRevision: UInt64?
    public let attempt: Int
    public let durationNanoseconds: UInt64
    public let onMainThread: Bool
    public let uptimeNanoseconds: UInt64
    public init(context: MessageDerivationTraceContext, phase: Phase, inputRevision: UInt64,
        outputRevision: UInt64? = nil, attempt: Int, durationNanoseconds: UInt64 = 0, onMainThread: Bool, uptimeNanoseconds: UInt64 = 0) {
        self.context = context; self.phase = phase; self.inputRevision = inputRevision
        self.outputRevision = outputRevision; self.attempt = attempt
        self.durationNanoseconds = durationNanoseconds; self.onMainThread = onMainThread
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
