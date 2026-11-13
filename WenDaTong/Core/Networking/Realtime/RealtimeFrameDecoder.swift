import Foundation
import IM4Data

// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
/// Only immutable, checked Sendable values cross the decoder actor boundary.
typealias RealtimeFrameInput = IM4Data.RealtimeFrameInput // WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111

struct RealtimeDecodedMessage: Sendable {
    // The wrapper distinguishes a completed nil result from an unprepared envelope.
    let value: RemoteMessage?
#if DEBUG
    let decodedOnMainThread = Thread.isMainThread
#endif
}

// WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
struct RealtimeDecodedSidecar: Sendable {
    enum Value: Sendable {
        case extra(RemoteMessageExtra?)
        case receipt(RemoteMessageReceipt?)
    }

    // A present case with a nil DTO is a completed decode attempt.
    let value: Value
#if DEBUG
    let decodedOnMainThread = Thread.isMainThread
#endif
}
// WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END

struct RealtimeDecodedFrame: Sendable {
    let envelope: RealtimeEnvelope
    let expansion: RealtimeBatchExpansionResult?
}

/// One worker per original receive loop. The loop awaits it before reading another frame.
actor RealtimeFrameDecoder {
    private let codec: any WireCodec
    init(codec: any WireCodec) { self.codec = codec }

    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
    func decode(_ input: RealtimeFrameInput) -> RealtimeDecodedFrame? {
        Self.decode(input, using: codec, prepareSidecars: true)
    }

    /// Synchronous injection continues to use the AppState decoder for sidecars.
    nonisolated static func decode(_ input: RealtimeFrameInput, using codec: any WireCodec) -> RealtimeDecodedFrame? {
        decode(input, using: codec, prepareSidecars: false)
    }

    private nonisolated static func decode(_ input: RealtimeFrameInput, using codec: any WireCodec,
                                           prepareSidecars: Bool) -> RealtimeDecodedFrame? {
        guard let data = input.acceptedWireData() else { return nil }
        guard var envelope = try? codec.decode(RealtimeEnvelope.self, from: data) else { return nil }
        let decoder = JSONDecoder() // Same default strategy as AppState.realtimeDecoder, never shared.
        func prepare(_ value: RealtimeEnvelope) -> RealtimeEnvelope {
            var result = value
            switch value.type {
            case "message", "message_push", "send_ack":
                result.decodedMessage = RealtimeDecodedMessage(value: RealtimeMessagePayloadDecoder.decode(value, using: decoder))
            case "message_extra" where prepareSidecars:
                result.decodedSidecar = RealtimeDecodedSidecar(value: .extra(RealtimeMessagePayloadDecoder.decodeSidecar(
                    RemoteMessageExtra.self, key: "extra", envelope: value, using: decoder)))
            case "message_receipt" where prepareSidecars:
                result.decodedSidecar = RealtimeDecodedSidecar(value: .receipt(RealtimeMessagePayloadDecoder.decodeSidecar(
                    RemoteMessageReceipt.self, key: "receipt", envelope: value, using: decoder)))
            default:
                break
            }
            return result
        }
        // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END
        if envelope.type == "batch" {
            let expansion = RealtimeBatchExpander.expand(envelope)
            return RealtimeDecodedFrame(envelope: envelope, expansion: RealtimeBatchExpansionResult(
                frames: expansion.frames.map(prepare), visitedElements: expansion.visitedElements,
                malformedElements: expansion.malformedElements, droppedForDepth: expansion.droppedForDepth,
                droppedForLimit: expansion.droppedForLimit))
        }
        envelope = prepare(envelope)
        return RealtimeDecodedFrame(envelope: envelope, expansion: nil)
    }
}

enum RealtimeMessagePayloadDecoder {
    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
    static func decodeSidecar<T: Decodable>(_ type: T.Type, key: String, envelope: RealtimeEnvelope,
                                             using decoder: JSONDecoder) -> T? {
        func decodeObject(_ object: [String: JSONValue]) -> T? {
            guard let data = try? JSONSerialization.data(withJSONObject: object.mapValues(\.anyValue)) else { return nil }
            return try? decoder.decode(type, from: data)
        }
        // A malformed nested DTO still falls through to the original flat payload.
        // A non-object cannot decode as either sidecar DTO.
        return envelope.payload[key]?.objectValue.flatMap(decodeObject) ?? decodeObject(envelope.payload)
    }
    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END

    /// Preserve the original JSONValue -> Foundation JSON -> typed DTO semantics.
    static func decode(_ envelope: RealtimeEnvelope, using decoder: JSONDecoder) -> RemoteMessage? {
        if let value = envelope.payload["message"] {
            // A typed message requires an object. Foundation raises an uncaught ObjC
            // exception for scalar/null top-level JSON writes; reject before that API.
            guard case .object = value,
                  let data = try? JSONSerialization.data(withJSONObject: value.anyValue) else { return nil }
            return try? decoder.decode(RemoteMessage.self, from: data)
        }
        // Invalid nested message must not be reinterpreted as a different outer message.
        guard envelope.payload["message"] == nil,
              let data = try? JSONSerialization.data(withJSONObject: envelope.payload.mapValues(\.anyValue)),
              let message = try? decoder.decode(RemoteMessage.self, from: data),
              message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" else { return nil }
        return message
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
