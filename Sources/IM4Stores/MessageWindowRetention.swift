// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import IM4Domain

public enum MessageWindowRetention: Equatable, Sendable {
    case preserveLoadedHistory
    case latestTail(limit: Int)
}

public func retainedConversationMessages(_ messages: [ChatMessage], for retention: MessageWindowRetention) -> [ChatMessage] {
    guard case .latestTail(let limit) = retention else { return messages }
    let boundedLimit = max(1, limit)
    let timelineMessages = messages.filter { message in
        !message.isPinnedContextOnly && !isPendingLocalMessage(message)
    }
    guard timelineMessages.count > boundedLimit else { return messages }
    let tailIDs = Set(timelineMessages.suffix(boundedLimit).map(\.id))
    var retained = messages.filter { message in
        tailIDs.contains(message.id)
            || isPendingLocalMessage(message)
            || message.isPinnedContextOnly
    }
    retained.sort(by: messageTimelinePrecedes)
    return retained
}

private func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
    message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
}

private func messageTimelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
    if lhs.channelSeq > 0, rhs.channelSeq > 0, lhs.channelSeq != rhs.channelSeq {
        return lhs.channelSeq < rhs.channelSeq
    }
    let lhsDate = lhs.createdAt ?? Date.distantPast
    let rhsDate = rhs.createdAt ?? Date.distantPast
    if lhsDate != rhsDate { return lhsDate < rhsDate }
    return lhs.id < rhs.id
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END
