import Foundation

public enum SyncEngineOperation: String, Sendable, Equatable {
    case conversationMessages
    case olderMessages
    case remoteSnapshot
    case realtimeRecovery
    case messageExtra
    case readReceipt
    case readAck
    case pinnedMessages
}

public struct SyncEngineRequest: Sendable, Equatable {
    public let operation: SyncEngineOperation
    public let conversationID: String?
    public let historyKey: String?
    public let reason: String

    public init(
        operation: SyncEngineOperation,
        conversationID: String? = nil,
        historyKey: String? = nil,
        reason: String
    ) {
        self.operation = operation
        self.conversationID = conversationID
        self.historyKey = historyKey
        self.reason = reason
    }

    public var inFlightKey: String {
        if let historyKey {
            return "\(operation.rawValue):history:\(historyKey)"
        }
        if let conversationID, !conversationID.isEmpty {
            return "\(operation.rawValue):conversation:\(conversationID)"
        }
        return "\(operation.rawValue):global"
    }
}

public struct SyncEngineResult: Sendable, Equatable {
    public let request: SyncEngineRequest
    public let started: Bool
    public let skippedReason: String?

    public static func started(_ request: SyncEngineRequest) -> SyncEngineResult {
        SyncEngineResult(request: request, started: true, skippedReason: nil)
    }

    public static func skipped(_ request: SyncEngineRequest, reason: String) -> SyncEngineResult {
        SyncEngineResult(request: request, started: false, skippedReason: reason)
    }

    public init(request: SyncEngineRequest, started: Bool, skippedReason: String?) {
        self.request = request
        self.started = started
        self.skippedReason = skippedReason
    }
}

public protocol ConversationMessageSyncEngine: AnyObject, Sendable {
    func begin(_ request: SyncEngineRequest) -> SyncEngineResult
    func finish(_ request: SyncEngineRequest)
    func isInFlight(_ request: SyncEngineRequest) -> Bool
    func reset()
}
