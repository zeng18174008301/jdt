// WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111_BEGIN
import Foundation

public enum RealtimeFrameInput: Sendable {
    case text(String), data(Data)

    public init?(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text): self = .text(text)
        case .data(let data): self = .data(data)
        @unknown default: return nil
        }
    }

    public func acceptedWireData() -> Data? {
        let data: Data
        switch self {
        case .text(let text):
            guard RealtimeBatchExpander.acceptsWirePayload(byteCount: text.utf8.count) else {
                print("[JHT Realtime] frame_skip reason=wire_limit")
                return nil
            }
            data = Data(text.utf8)
        case .data(let binary):
            guard RealtimeBatchExpander.acceptsWirePayload(byteCount: binary.count) else {
                print("[JHT Realtime] frame_skip reason=wire_limit bytes=\(binary.count)")
                return nil
            }
            data = binary
        }
        return data
    }
}

public struct RealtimeWireEnvelope: Decodable, Sendable {
    public let type: String
    public let requestID: String?
    public let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case payload
    }

    public init(type: String, requestID: String?, payload: [String: JSONValue]) {
        self.type = type
        self.requestID = requestID
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
    }
}

/// Supplies wire fields and constructs an unprepared child without reboxing the App's carrier.
public protocol RealtimeBatchWireFrame: Sendable {
    var type: String { get }
    var requestID: String? { get }
    var payload: [String: JSONValue] { get }

    init(type: String, requestID: String?, payload: [String: JSONValue])
}

public struct RealtimeBatchExpansionResult<Frame: Sendable>: Sendable {
    public let frames: [Frame]
    public let visitedElements: Int
    public let malformedElements: Int
    public let droppedForDepth: Int
    public let droppedForLimit: Int

    public init(frames: [Frame], visitedElements: Int, malformedElements: Int, droppedForDepth: Int, droppedForLimit: Int) {
        self.frames = frames
        self.visitedElements = visitedElements
        self.malformedElements = malformedElements
        self.droppedForDepth = droppedForDepth
        self.droppedForLimit = droppedForLimit
    }

    public var didDropInput: Bool {
        malformedElements > 0 || droppedForDepth > 0 || droppedForLimit > 0
    }
}

public enum RealtimeBatchExpander {
    public static let maximumDepth = 16
    public static let maximumFrames = 256
    public static let maximumElements = 512
    public static let maximumWireBytes = 1_048_576

    public static func acceptsWirePayload(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumWireBytes
    }

    private struct WorkItem<Frame: RealtimeBatchWireFrame> {
        let envelope: Frame
        let depth: Int
    }

    public static func expand<Frame: RealtimeBatchWireFrame>(_ root: Frame) -> RealtimeBatchExpansionResult<Frame> {
        var stack = [WorkItem(envelope: root, depth: 0)]
        var frames: [Frame] = []
        var visitedElements = 0
        var malformedElements = 0
        var droppedForDepth = 0
        var droppedForLimit = 0

        while let item = stack.popLast() {
            let type = item.envelope.type
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard type == "batch" else {
                if frames.count < maximumFrames {
                    frames.append(item.envelope)
                } else {
                    droppedForLimit += 1
                }
                continue
            }
            guard case .array(let nestedFrames)? = item.envelope.payload["frames"] else {
                malformedElements += 1
                continue
            }
            guard item.depth < maximumDepth else {
                droppedForDepth += nestedFrames.count
                continue
            }
            let remainingElementBudget = max(0, maximumElements - visitedElements)
            let acceptedCount = min(nestedFrames.count, remainingElementBudget)
            if acceptedCount < nestedFrames.count {
                droppedForLimit += nestedFrames.count - acceptedCount
            }
            visitedElements += acceptedCount
            var accepted: [WorkItem<Frame>] = []
            accepted.reserveCapacity(acceptedCount)
            for frame in nestedFrames.prefix(acceptedCount) {
                guard case .object(let object) = frame else {
                    malformedElements += 1
                    continue
                }
                let nestedType = (object["type"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nestedType.isEmpty else {
                    malformedElements += 1
                    continue
                }
                let requestID = object["request_id"]?.stringValue
                    ?? object["requestID"]?.stringValue
                let payload = object["payload"]?.objectValue
                    ?? object["data"]?.objectValue
                    ?? [:]
                accepted.append(WorkItem(
                    envelope: Frame(
                        type: nestedType,
                        requestID: requestID,
                        payload: payload
                    ),
                    depth: item.depth + 1
                ))
            }
            stack.append(contentsOf: accepted.reversed())
        }

        return RealtimeBatchExpansionResult(
            frames: frames,
            visitedElements: visitedElements,
            malformedElements: malformedElements,
            droppedForDepth: droppedForDepth,
            droppedForLimit: droppedForLimit
        )
    }
}
// WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111_END
