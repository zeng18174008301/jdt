// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_BEGIN
import Foundation
import XCTest
import IM4Data
@testable import WenDaTong

extension HTTPTransportTests {
    func testDataHTTPErrorEnvelopeKeepsAppMergeAndActualRateLimitClassification() async throws {
        captureA43RuntimeLoadedImages()
        let bytes = Data(#"{"ok":false,"code":"outer_code","reason_code":"outer_reason","message":"outer message","error":{"code":"rate_limited","reason_code":"nested_reason","message":"请稍后重试","retry_after_seconds":"7","remaining_seconds":"12","peer_im_uid":"peer-1","can_apply_friend":"unknown"},"data":{"code":"data_code","message":"data message","retry_after_seconds":15}}"#.utf8)
        let raw = try JSONDecoder().decode(IM4Data.APIErrorEnvelope.self, from: bytes)
        let resolved = try XCTUnwrap(raw.resolvedError)
        XCTAssertEqual(resolved.code, "rate_limited")
        XCTAssertEqual(resolved.reasonCode, "nested_reason")
        XCTAssertEqual(resolved.message, "请稍后重试")
        XCTAssertEqual(resolved.retryAfterSeconds, 7)
        XCTAssertEqual(resolved.remainingSeconds, 12)
        XCTAssertEqual(resolved.peerIMUID, "peer-1")
        XCTAssertNil(resolved.canApplyFriend)
        let security = try JSONDecoder().decode(IM4Data.APILoginSecurityEnvelope.self,
            from: Data(#"{"code":"outer","reason_code":"outer_reason","message":"outer message","error":{"code":"nested","message":"nested message"}}"#.utf8))
        XCTAssertEqual(security.resolvedError?.code, "nested")
        XCTAssertEqual(security.resolvedError?.reasonCode, "outer_reason")
        XCTAssertEqual(security.resolvedError?.message, "nested message")
        let transport = FakeHTTPTransport(results: [.init(data: bytes, isHTTPResponse: true, statusCode: 429)])
        let client = makeClient(transport: transport)
        do {
            _ = try await client.listDevices(context: makeContext())
            XCTFail("rate-limited response unexpectedly succeeded")
        } catch let IMAPIError.rateLimited(code, message, retryAfter, _) {
            XCTAssertEqual(code, "rate_limited")
            XCTAssertEqual(message, "请稍后重试")
            XCTAssertEqual(retryAfter, 7)
        }
        XCTAssertEqual(transport.requests().count, 1)
    }

    func testDataHTTPEnvelopeKeepsStringErrorMalformedNilAndListScalarContracts() throws {
        captureA43RuntimeLoadedImages()
        let decoder = JSONDecoder()
        let stringError = try decoder.decode(IM4Data.APIEnvelopeError.self, from: Data(#""device_disabled""#.utf8))
        XCTAssertEqual(stringError.code, "device_disabled")
        XCTAssertEqual(stringError.message, "device_disabled")
        XCTAssertNil(stringError.reasonCode)
        let malformed = Data(#"{"ok":true,"data":{"items":[]},"error":42}"#.utf8)
        XCTAssertNil(try? decoder.decode(IM4Data.APIErrorEnvelope.self, from: malformed))
        XCTAssertNil(try? decoder.decode(IM4Data.APIEnvelope<IM4Data.RemoteList<EnvelopeProbe>>.self, from: malformed))
        let list = try decoder.decode(IM4Data.RemoteList<EnvelopeProbe>.self,
            from: Data(#"{"items":[{"id":"row-1"}],"self_member":{"id":"self-1"},"total_count":"17","limit":2,"offset":"4","hasMore":"yes","nextOffset":"6","next_cursor":"opaque-cursor"}"#.utf8))
        XCTAssertEqual(list.items.map(\.id), ["row-1"])
        XCTAssertEqual(list.selfMember?.id, "self-1")
        XCTAssertEqual(list.total, 17); XCTAssertEqual(list.limit, 2); XCTAssertEqual(list.offset, 4)
        XCTAssertEqual(list.hasMore, true); XCTAssertEqual(list.nextOffset, 6); XCTAssertEqual(list.nextCursor, "opaque-cursor")
    }
}

private struct EnvelopeProbe: Decodable { let id: String }
// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_END
