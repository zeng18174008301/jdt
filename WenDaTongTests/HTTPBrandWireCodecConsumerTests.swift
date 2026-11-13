// WDT_IOS1_DATA_BRAND_WIRE_CODECS_20261111_BEGIN
import Foundation
import CryptoKit
import XCTest
import IM4Data
@testable import WenDaTong

extension HTTPTransportTests {
    func testDataBrandCodecIsActualHTTPRequestAndTypedResponseConsumer() async throws {
        captureA43RuntimeLoadedImages()
        let profile = brandWireConsumerProfile()
        let codec: any WireCodec = IM4Data.EncryptedEnvelopeWireCodec(brandProfile: profile)
        // Independently produce branded wire bytes with CryptoKit, without using the moved encoder.
        let response = try brandWireConsumerCipher(["o": true, "d": ["u": true, "r": false, "a": true]])
        let transport = FakeHTTPTransport(results: [.init(data: response, isHTTPResponse: true, statusCode: 200)])
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [], httpTransport: transport, wireCodec: codec, runtimeRouteStore: isolatedRuntimeRouteStore())
        let result = try await client.changeMyPassword(context: makeContext(), currentPassword: "synthetic-old", newPassword: "synthetic-new")
        XCTAssertTrue(result.updated); XCTAssertFalse(result.requiresRelogin); XCTAssertTrue(result.sessionRemainsActive)
        XCTAssertEqual(transport.requests().count, 1)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.path, "/api/tenant/me/password")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), Set(["alg", "kid", "body"]))
        XCTAssertEqual(envelope["alg"] as? String, "aes-gcm-256")
        XCTAssertEqual(envelope["kid"] as? String, "synthetic-wire-kid")
        let combined = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["body"] as? String)))
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: Data(repeating: 0x59, count: 32)))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: String])
        XCTAssertEqual(payload, ["c": "synthetic-old", "l": "synthetic-old", "n": "synthetic-new"])
    }

    func testDataBrandCodecFeedsActualRealtimeActorAndPreparedNilResult() async throws {
        captureA43RuntimeLoadedImages()
        let codec: any WireCodec = IM4Data.EncryptedEnvelopeWireCodec(brandProfile: brandWireConsumerProfile())
        let bytes = try brandWireConsumerCipher(["t": "send_ack", "q": "synthetic-request", "p": ["st": "accepted"]])
        let decoder = RealtimeFrameDecoder(codec: codec)
        let result = await decoder.decode(.data(bytes))
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(frame.envelope.type, "send_ack")
        XCTAssertEqual(frame.envelope.requestID, "synthetic-request")
        XCTAssertEqual(frame.envelope.payload["status"]?.stringValue, "accepted")
        XCTAssertNotNil(frame.envelope.decodedMessage)
        XCTAssertNil(frame.envelope.decodedMessage?.value)
        XCTAssertNil(frame.expansion)
    }

    private func brandWireConsumerProfile() -> WireBrandProfile {
        WireBrandProfile(identifier: "synthetic-brand", fieldMapping: .init(name: "synthetic-mapping", outboundFields: [
            "ok": "o", "data": "d", "updated": "u", "requires_relogin": "r", "session_remains_active": "a",
            "current_password": "c", "old_password": "l", "new_password": "n",
            "type": "t", "request_id": "q", "payload": "p", "status": "st"]),
            encryptionProfile: .init(keyID: "synthetic-wire-kid", sharedSecret: Data(repeating: 0x59, count: 32)))
    }

    private func brandWireConsumerCipher(_ branded: [String: Any]) throws -> Data {
        let clear = try JSONSerialization.data(withJSONObject: branded)
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: Data(repeating: 0x59, count: 32)))
        let combined = try XCTUnwrap(sealed.combined)
        return try JSONSerialization.data(withJSONObject: ["alg": "aes-gcm-256", "kid": "synthetic-wire-kid", "body": combined.base64EncodedString()])
    }
}
// WDT_IOS1_DATA_BRAND_WIRE_CODECS_20261111_END
