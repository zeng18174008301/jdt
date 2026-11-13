// WDT_IOS1_DATA_NETWORK_DTO_20261110_BEGIN
import Foundation
import XCTest
import IM4Data
@testable import WenDaTong

final class DataNetworkDTOBoundaryTests: XCTestCase {
    func testOriginalAppAliasesResolveToDataDTOs() {
        let values: [Any.Type] = [RemoteAvatarUploadData.self, RemoteUploadedFileResponse.self,
            RemoteAvatarFile.self, RemoteSignedUpload.self, RemoteAvatarCommitData.self,
            RemoteAvatarProfile.self, RemoteStickerVariant.self, RemoteUserSticker.self,
            RemoteStickerPack.self, RemoteSticker.self, RemoteStickerProcessingTask.self,
            RemoteUserStickerCommitResult.self]
        for value in values { XCTAssertTrue(String(reflecting: value).hasPrefix("IM4Data.")) }
    }

    func testUploadDTOFallbackOrderDefaultsAndOpaqueRequestFields() throws {
        let body = Data(#"{"file":{"file_id":"f","preview_url":"","thumbnail_url":"primary","thumb_url":"secondary","duration_ms":"1500","unknown":true},"upload":{"url":"https://example.invalid/object?v=fixture","headers":{"X-Fixture":"Value"}}}"#.utf8)
        let result = try JSONDecoder().decode(RemoteAvatarUploadData.self, from: body)
        XCTAssertEqual(result.file.id, "f")
        XCTAssertEqual(result.file.thumbnailURL, "primary")
        XCTAssertEqual(result.file.durationSeconds, 1.5)
        XCTAssertEqual(result.upload?.method, "PUT")
        XCTAssertEqual(result.upload?.headers, ["X-Fixture": "Value"])
        XCTAssertEqual(result.upload?.url, "https://example.invalid/object?v=fixture")
        let flat = try JSONDecoder().decode(RemoteUploadedFileResponse.self, from: Data(#"{"id":"flat"}"#.utf8))
        XCTAssertEqual(flat.file.id, "flat")
    }

    func testStickerDTOInt64PrecisionNullUnknownAndEquality() throws {
        let body = Data(#"{"id":"s","size_bytes":9223372036854775807,"duration_ms":"1500","status":"future_status","variants":[{"url":"","asset_url":"ignored","size_bytes":"9223372036854775807"}],"unknown":true,"created_at":"opaque-date"}"#.utf8)
        let value = try JSONDecoder().decode(RemoteSticker.self, from: body)
        XCTAssertEqual(value.sizeBytes, Int64.max)
        XCTAssertEqual(value.variants.first?.sizeBytes, Int64.max)
        XCTAssertEqual(value.variants.first?.url, "")
        XCTAssertEqual(value.durationMS, 1500)
        XCTAssertEqual(value.status, "future_status")
        XCTAssertEqual(value.createdAt, "opaque-date")
        XCTAssertEqual(value, try JSONDecoder().decode(RemoteSticker.self, from: body))
        let empty = try JSONDecoder().decode(RemoteUserStickerCommitResult.self, from: Data(#"{"sticker":{},"task":null}"#.utf8))
        XCTAssertNil(empty.task)
        XCTAssertEqual(empty.sticker.variants, [])
    }

    func testMalformedDTOStillThrowsFoundationDecodingErrorWithOriginalCodingPath() throws {
        do {
            _ = try JSONDecoder().decode(RemoteAvatarUploadData.self, from: Data(#"{"file":{"id":true}}"#.utf8))
            XCTFail("wrong field type unexpectedly accepted")
        } catch DecodingError.typeMismatch(_, let context) {
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["file", "id"])
        }
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteUserStickerCommitResult.self, from: Data(#"{"task":null}"#.utf8)))
    }
}
// WDT_IOS1_DATA_NETWORK_DTO_20261110_END
