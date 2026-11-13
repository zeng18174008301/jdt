// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import IM4Domain

@MainActor
public final class MessageMemoryDiagnostic {
    private let onStaged: () -> Void
    private let onCommandFinished: () -> Void
    private let onInstalled: (UInt64, [String: ScopedMessageMemoryStore.MessageWindowChange]) -> String?
    private let onPublicationFinished: () -> Void
    private let onTimelineObserved: (UInt64, [ChatMessage], Bool) -> Void

    public init(onStaged: @escaping () -> Void, onCommandFinished: @escaping () -> Void,
        onInstalled: @escaping (UInt64, [String: ScopedMessageMemoryStore.MessageWindowChange]) -> String?,
        onPublicationFinished: @escaping () -> Void,
        onTimelineObserved: @escaping (UInt64, [ChatMessage], Bool) -> Void) {
        self.onStaged = onStaged; self.onCommandFinished = onCommandFinished
        self.onInstalled = onInstalled; self.onPublicationFinished = onPublicationFinished
        self.onTimelineObserved = onTimelineObserved
    }
    func staged() { onStaged() }
    func commandFinished() { onCommandFinished() }
    func publicationFinished() { onPublicationFinished() }
    public func timelineObserved(revision: UInt64, projected: [ChatMessage], sceneActive: Bool) {
        onTimelineObserved(revision, projected, sceneActive)
    }
    static func installed(_ frame: ConversationMemoryFrame,
        changes: [String: ScopedMessageMemoryStore.MessageWindowChange]) -> [String: [MessageMemoryDiagnostic]] {
        var result: [String: [MessageMemoryDiagnostic]] = [:]
        for diagnostic in frame.realtimeSignposts {
            if let id = diagnostic.onInstalled(frame.revision, changes) {
                result[id, default: []].append(diagnostic)
            }
        }
        return result
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END
