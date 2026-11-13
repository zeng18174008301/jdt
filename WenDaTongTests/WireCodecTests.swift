import Foundation
import XCTest
@testable import WenDaTong

final class WireCodecTests: XCTestCase {
    func testJSONWireCodecEncodesJSONObjectWithoutChangingKeys() throws {
        let codec = JSONWireCodec()
        let data = try codec.encodeJSONObject([
            "tenant_id": "tenant-1",
            "device_id": "device-1",
            "payload": [
                "client_msg_no": "msg-1"
            ]
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])

        XCTAssertEqual(object["tenant_id"] as? String, "tenant-1")
        XCTAssertEqual(object["device_id"] as? String, "device-1")
        XCTAssertEqual(payload["client_msg_no"] as? String, "msg-1")
    }

    func testJSONWireCodecRejectsInvalidJSONObject() {
        let codec = JSONWireCodec()

        assertThrowsWireCodecError(.invalidJSONObject, try codec.encodeJSONObject([
            "tenant_id": "tenant-1",
            "created_at": Date()
        ]))
    }

    func testJSONWireCodecDecodesAPIEnvelope() throws {
        let codec = JSONWireCodec()
        let data = Data(#"{"ok":false,"error":{"code":"forbidden","message":"forbidden: device disabled"}}"#.utf8)
        let envelope = try codec.decode(APIEnvelope<EmptyPayload>.self, from: data)

        XCTAssertEqual(envelope.ok, false)
        XCTAssertEqual(envelope.error?.code, "forbidden")
        XCTAssertEqual(envelope.error?.message, "forbidden: device disabled")
    }

    func testJSONWireCodecDecodesRealtimeEnvelope() throws {
        let codec = JSONWireCodec()
        let data = Data(#"{"type":"error","request_id":"req-1","payload":{"code":"forbidden","message":"device binding violation"}}"#.utf8)
        let envelope = try codec.decode(RealtimeEnvelope.self, from: data)

        XCTAssertEqual(envelope.type, "error")
        XCTAssertEqual(envelope.requestID, "req-1")
        XCTAssertEqual(envelope.payload["code"]?.stringValue, "forbidden")
        XCTAssertEqual(envelope.payload["message"]?.stringValue, "device binding violation")
    }

    func testFieldMappingWireCodecEncodesBrandFieldsAndDecodesCanonicalFields() throws {
        let codec = FieldMappingWireCodec(
            brandProfile: WireBrandProfile(
                identifier: "fixture-brand",
                fieldMapping: WireFieldMappingProfile(
                    name: "fixture-fields",
                    outboundFields: [
                        "tenant_id": "t",
                        "device_id": "d",
                        "payload": "p",
                        "client_msg_no": "c",
                        "text": "x"
                    ]
                ),
                encryptionKeyID: "fixture-key"
            )
        )

        let encodedData = try codec.encodeJSONObject([
            "tenant_id": "tenant-1",
            "device_id": "device-1",
            "payload": [
                "client_msg_no": "msg-1",
                "text": "hello"
            ]
        ])
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        let encodedPayload = try XCTUnwrap(encodedObject["p"] as? [String: Any])

        XCTAssertNil(encodedObject["tenant_id"])
        XCTAssertEqual(encodedObject["t"] as? String, "tenant-1")
        XCTAssertEqual(encodedObject["d"] as? String, "device-1")
        XCTAssertEqual(encodedPayload["c"] as? String, "msg-1")
        XCTAssertEqual(encodedPayload["x"] as? String, "hello")

        let inboundData = Data(#"{"t":"tenant-1","d":"device-1","p":{"c":"msg-1","x":"hello"}}"#.utf8)
        let decoded = try codec.decode(CanonicalWireFixture.self, from: inboundData)

        XCTAssertEqual(decoded.tenantID, "tenant-1")
        XCTAssertEqual(decoded.deviceID, "device-1")
        XCTAssertEqual(decoded.payload.clientMessageID, "msg-1")
        XCTAssertEqual(decoded.payload.text, "hello")
    }

    func testEncryptedEnvelopeWireCodecRoundTripsMappedBrandPayload() throws {
        let codec = EncryptedEnvelopeWireCodec(brandProfile: makeSecureBrandProfile())

        let encryptedData = try codec.encodeJSONObject([
            "tenant_id": "tenant-1",
            "device_id": "device-1",
            "payload": [
                "client_msg_no": "msg-1",
                "text": "hello"
            ]
        ])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encryptedData) as? [String: Any])
        let body = try XCTUnwrap(envelope["body"] as? String)
        let encryptedText = String(data: encryptedData, encoding: .utf8) ?? ""

        XCTAssertEqual(envelope["alg"] as? String, "aes-gcm-256")
        XCTAssertEqual(envelope["kid"] as? String, "fixture-key-1")
        XCTAssertFalse(body.isEmpty)
        XCTAssertFalse(encryptedText.contains("tenant-1"))
        XCTAssertFalse(encryptedText.contains("client_msg_no"))
        XCTAssertFalse(encryptedText.contains("hello"))

        let decoded = try codec.decode(CanonicalWireFixture.self, from: encryptedData)

        XCTAssertEqual(decoded.tenantID, "tenant-1")
        XCTAssertEqual(decoded.deviceID, "device-1")
        XCTAssertEqual(decoded.payload.clientMessageID, "msg-1")
        XCTAssertEqual(decoded.payload.text, "hello")
    }

    func testEncryptedEnvelopeWireCodecRequiresEncryptionProfile() throws {
        let codec = EncryptedEnvelopeWireCodec(brandProfile: .canonical)
        let envelopeData = try JSONWireCodec().encodeJSONObject([
            "alg": "aes-gcm-256",
            "kid": "fixture-key-1",
            "body": "AA=="
        ])

        assertThrowsWireCodecError(.encryptionProfileMissing, try codec.encodeJSONObject([
            "tenant_id": "tenant-1"
        ]))
        assertThrowsWireCodecError(
            .encryptionProfileMissing,
            try codec.decode(CanonicalWireFixture.self, from: envelopeData)
        )
    }

    func testEncryptedEnvelopeWireCodecRejectsInvalidEnvelopeMetadata() throws {
        let codec = EncryptedEnvelopeWireCodec(brandProfile: makeSecureBrandProfile())
        let envelopes: [[String: String]] = [
            [
                "alg": "aes-gcm-128",
                "kid": "fixture-key-1",
                "body": "AA=="
            ],
            [
                "alg": "aes-gcm-256",
                "kid": "other-key",
                "body": "AA=="
            ],
            [
                "alg": "aes-gcm-256",
                "kid": "fixture-key-1",
                "body": "not-base64"
            ],
            [
                "alg": "aes-gcm-256",
                "kid": "fixture-key-1",
                "body": "AA=="
            ]
        ]

        for envelope in envelopes {
            let data = try JSONWireCodec().encodeJSONObject(envelope)
            assertThrowsWireCodecError(
                .invalidEncryptedEnvelope,
                try codec.decode(CanonicalWireFixture.self, from: data)
            )
        }
    }

    func testEncryptedEnvelopeWireCodecMapsTamperedCiphertextToInvalidEnvelope() throws {
        let codec = EncryptedEnvelopeWireCodec(brandProfile: makeSecureBrandProfile())
        let encryptedData = try codec.encodeJSONObject([
            "tenant_id": "tenant-1",
            "device_id": "device-1",
            "payload": [
                "client_msg_no": "msg-1",
                "text": "hello"
            ]
        ])
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encryptedData) as? [String: Any])
        let body = try XCTUnwrap(envelope["body"] as? String)
        var combined = try XCTUnwrap(Data(base64Encoded: body))
        combined[combined.startIndex] = combined[combined.startIndex] ^ 0xff
        envelope["body"] = combined.base64EncodedString()
        let tamperedData = try JSONSerialization.data(withJSONObject: envelope)

        assertThrowsWireCodecError(
            .invalidEncryptedEnvelope,
            try codec.decode(CanonicalWireFixture.self, from: tamperedData)
        )
    }

    private func makeSecureBrandProfile() -> WireBrandProfile {
        WireBrandProfile(
            identifier: "secure-fixture-brand",
            fieldMapping: WireFieldMappingProfile(
                name: "secure-fixture-fields",
                outboundFields: [
                    "tenant_id": "t",
                    "device_id": "d",
                    "payload": "p",
                    "client_msg_no": "c",
                    "text": "x"
                ]
            ),
            encryptionProfile: WireEncryptionProfile(
                keyID: "fixture-key-1",
                sharedSecret: Data("0123456789abcdef0123456789abcdef".utf8)
            )
        )
    }

    private func assertThrowsWireCodecError<T>(
        _ expectedError: WireCodecError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? WireCodecError, expectedError, file: file, line: line)
        }
    }
}

private struct CanonicalWireFixture: Decodable {
    let tenantID: String
    let deviceID: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case deviceID = "device_id"
        case payload
    }

    struct Payload: Decodable {
        let clientMessageID: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case clientMessageID = "client_msg_no"
            case text
        }
    }
}

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN
extension WireCodecTests {
    func testMovedWireCodecErrorsKeepOriginalNSErrorDomainAndCodes() {
        let errors: [WireCodecError] = [.invalidJSONObject, .encryptionProfileMissing, .invalidEncryptedEnvelope]
        for (expectedCode, error) in errors.enumerated() {
            let value = error as NSError
            XCTAssertEqual(value.domain, "BlueStoneIM.WireCodecError")
            XCTAssertEqual(value.code, expectedCode)
            XCTAssertTrue(value.userInfo.isEmpty)
            let legacyBridge = NSError(domain: "BlueStoneIM.WireCodecError", code: expectedCode, userInfo: [:])
            let erased: any Error = error
            XCTAssertNil(erased as? any LocalizedError)
            XCTAssertEqual(erased.localizedDescription, legacyBridge.localizedDescription)
            XCTAssertEqual(value.localizedDescription, legacyBridge.localizedDescription)
            XCTAssertEqual((value as Error).localizedDescription, legacyBridge.localizedDescription)
        }
    }
}
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN
extension DomainStoreTests {
    func testCoreCodecFailureKeepsExistingErrorPresentationAndLogRedaction() throws {
        let state = AppState(api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
                             apiContextOverride: makeAuthenticatedAPIContext())
        let fallback = "codec failure"
        let original = NSError(domain: "BlueStoneIM.WireCodecError", code: 0, userInfo: [:])
        state.handleRemoteError(original, fallback: fallback)
        let originalToast = state.toast
        XCTAssertNotNil(originalToast)
        do {
            _ = try JSONWireCodec().encodeJSONObject(["not_json": Date()])
            XCTFail("expected the real Core codec to reject a non-JSON value")
        } catch {
            XCTAssertEqual(error as? WireCodecError, .invalidJSONObject)
            state.handleRemoteError(error, fallback: fallback)
            XCTAssertEqual(state.toast, originalToast)
            XCTAssertEqual(BackendUserMessageSanitizer.sanitize(error: error, fallback: fallback),
                           BackendUserMessageSanitizer.sanitize(error: original, fallback: fallback))
            XCTAssertEqual(IMAPIClient.redactedSensitiveLogText(error.localizedDescription),
                           IMAPIClient.redactedSensitiveLogText(original.localizedDescription))
        }
        struct LocalizedFailure: LocalizedError {
            var errorDescription: String? { "token=core-fixture-token secret=core-fixture-secret" }
        }
        let localized: any Error = LocalizedFailure()
        let bridge = localized as NSError
        XCTAssertEqual(localized.localizedDescription, bridge.localizedDescription)
        XCTAssertEqual((localized as? any LocalizedError)?.errorDescription, bridge.localizedDescription)
        XCTAssertEqual(BackendUserMessageSanitizer.sanitize(error: localized, fallback: fallback), fallback)
        state.handleRemoteError(localized, fallback: fallback)
        XCTAssertFalse(state.toast?.contains("core-fixture-token") ?? true)
        XCTAssertFalse(state.toast?.contains("core-fixture-secret") ?? true)
        let logText = IMAPIClient.redactedSensitiveLogText(localized.localizedDescription)
        XCTAssertFalse(logText.contains("core-fixture-token")); XCTAssertFalse(logText.contains("core-fixture-secret"))
    }
}
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END
