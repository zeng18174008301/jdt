@testable import IM4Features
import ImageIO
import UIKit
import SwiftUI
import XCTest
@testable import WenDaTong

@MainActor
final class DesignSystemTests: XCTestCase {

    // WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
    func testDefaultImageDecodeDownsamplesLargeSourceAndRejectsCorruption() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 2048), format: format)
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
            }
        let decoded = try XCTUnwrap(RemoteImageDecoder.image(from: data)?.cgImage)
        XCTAssertEqual(decoded.width, 2048)
        XCTAssertEqual(decoded.height, 1024)
        XCTAssertNil(RemoteImageDecoder.image(from: Data("broken".utf8), maxPixelSize: 320))
        XCTAssertNil(RemoteImageDecoder.image(from: Data()))
        XCTAssertEqual(AvatarImageCache.scopedCacheKey("image", maxPixelSize: nil), AvatarImageCache.scopedCacheKey("image", maxPixelSize: 2048))
    }

    func testDataURLBudgetRejectsOversizeAndPreservesValidEncodings() {
        let oversized = "data:image/png;base64," + String(repeating: "A", count: ((RemoteImageDecoder.maximumEncodedByteCount + 2) / 3) * 4 + 4)
        XCTAssertNil(RemoteImageDataURLDecoder.data(from: oversized))
        XCTAssertEqual(RemoteImageDataURLDecoder.data(from: "DATA:text/plain;base64,aGVsbG8="), Data("hello".utf8))
        XCTAssertEqual(RemoteImageDataURLDecoder.data(from: "data:text/plain,a%20b"), Data("a b".utf8))
    }

    func testPreviewFileBudgetRejectsOversizedFileBeforeReadingBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-budget-\(UUID()).jpg")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RemoteImageDecoder.maximumEncodedByteCount + 1))
        try handle.close()
        XCTAssertThrowsError(try RemoteImageDecoder.previewData(fromFileURL: url)) { error in
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    func testClearedImageCacheRejectsLateResultsForAllWaiters() async throws {
        let transport = SuspendedImageTransport(data: Self.makePNGData())
        let cache = AvatarImageCache(imageTransport: transport)
        let first = Task { await cache.remoteImage(for: "https://image.example.test/late.png") }
        while await transport.requestCount == 0 { await Task.yield() }
        var joinedStarted = false
        let joined = Task { @MainActor in
            joinedStarted = true
            return await cache.remoteImage(for: "https://image.example.test/late.png")
        }
        while !joinedStarted { await Task.yield() }
        cache.removeAllImages()
        await transport.resume()
        let firstResult = await first.value
        let joinedResult = await joined.value
        XCTAssertNil(firstResult)
        XCTAssertNil(joinedResult)
        XCTAssertNil(cache.peekImage(for: "https://image.example.test/late.png"))
    }

    func testImageCacheBoundsConcurrentTransportAcrossDistinctImages() async {
        let transport = ConcurrencyImageTransport(data: Self.makePNGData())
        let cache = AvatarImageCache(imageTransport: transport)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = await cache.remoteImage(for: "https://image.example.test/\(index).png")
                }
            }
        }
        let snapshot = await transport.snapshot()
        XCTAssertLessThanOrEqual(snapshot.peak, 2)
        XCTAssertEqual(snapshot.completed, 12)
        XCTAssertEqual(snapshot.running, 0)
    }
    // WDT_IOS1_IMAGE_BUDGET_20261023_END

    // WDT_IOS1_AVATAR_MEMORY_20261023_BEGIN
    func testAvatarSourceAppliesEXIFOrientationBeforeCropping() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let normalized = try XCTUnwrap(AvatarCropRenderer.sourceImage(data: output as Data, fileURL: nil))
        XCTAssertEqual(normalized.imageOrientation, .up)
        XCTAssertEqual(normalized.cgImage?.width, 40)
        XCTAssertEqual(normalized.cgImage?.height, 80)
        let crop = try XCTUnwrap(AvatarCropRenderer.croppedJPEG(image: normalized, previewSize: 280, outputPixelSize: 512, scale: 1, offset: .zero))
        XCTAssertEqual(UIImage(data: crop)?.cgImage?.width, 512)
        XCTAssertLessThanOrEqual(crop.count, AvatarCropRenderer.maximumJPEGByteCount)
    }
    // WDT_IOS1_AVATAR_MEMORY_20261023_END

    // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
    func testLocalThumbnailDownsamplesWithoutChangingCachedSource() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800), format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-perf-\(UUID()).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await AttachmentThumbnailDiskCache.localPreparedImage(from: url, maxPixelSize: 320)
        let image = try XCTUnwrap(result?.cgImage)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 160)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testLocalThumbnailStillHandlesMissingInvalidAndDefaultSizeInputs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-perf-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = await AttachmentThumbnailDiskCache.localPreparedImage(from: url, maxPixelSize: 320)
        XCTAssertNil(missing)
        try Data("invalid-image".utf8).write(to: url)
        let invalid = await AttachmentThumbnailDiskCache.localPreparedImage(from: url, maxPixelSize: 320)
        XCTAssertNil(invalid)
        let data = Self.makePNGData()
        try data.write(to: url)
        let result = await AttachmentThumbnailDiskCache.localPreparedImage(from: url)
        XCTAssertEqual(result?.cgImage?.width, UIImage(data: data)?.cgImage?.width)
        XCTAssertEqual(result?.cgImage?.height, UIImage(data: data)?.cgImage?.height)
    }

    func testThumbnailLoadGateKeepsItsLimitWhileWaitersAndNewArrivalsCompete() async {
        for limit in [1, 2] {
            let gate = AttachmentThumbnailLoadGate(limit: limit)
            let probe = ThumbnailConcurrencyProbe()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<64 {
                    group.addTask {
                        for _ in 0..<4 {
                            await gate.acquire()
                            await probe.enter()
                            await Task.yield()
                            await probe.leave()
                            await gate.release()
                        }
                    }
                }
            }
            let result = await probe.snapshot()
            XCTAssertLessThanOrEqual(result.peak, limit)
            XCTAssertEqual(result.active, 0)
            XCTAssertEqual(result.completed, 256)
        }
    }

    func testCancelledThumbnailWaiterCanReleaseSlotForNextLoad() async {
        let gate = AttachmentThumbnailLoadGate(limit: 1)
        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            let wasCancelled = Task.isCancelled
            await gate.release()
            return wasCancelled
        }
        await Task.yield()
        waiter.cancel()
        await gate.release()
        let cancelled = await waiter.value
        XCTAssertTrue(cancelled)
        await gate.acquire()
        await gate.release()
    }

    func testThumbnailCacheHitUsesAdmissionGateBeforeDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        // WDT_IOS1_THUMBNAIL_SOURCE_BINDING_20261112_BEGIN
        let loader = root.appendingPathComponent("WenDaTong/App/ChatAttachmentThumbnailLoader.swift")
        let featureChat = root.appendingPathComponent("Sources/IM4Features/Chat")
        let source = try String(contentsOf: loader, encoding: .utf8)
        let textBubbles = try String(contentsOf: featureChat.appendingPathComponent("ChatBubbleTextViews.swift"), encoding: .utf8)
        let mediaBubbles = try String(contentsOf: featureChat.appendingPathComponent("ChatMediaBubbleViews.swift"), encoding: .utf8)
        // WDT_IOS1_THUMBNAIL_SOURCE_BINDING_20261112_END
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        let start = try XCTUnwrap(source.range(of: "private func load() async {"))
        let localGate = try XCTUnwrap(source.range(of: "let gate = AttachmentThumbnailLoadGate.localDecodes", range: start.upperBound..<source.endIndex))
        let gate = try XCTUnwrap(source.range(of: "guard await gate.acquire() else { return }", range: localGate.upperBound..<source.endIndex))
        let local = try XCTUnwrap(source.range(of: "await AttachmentThumbnailDiskCache.localPreparedImage", range: start.upperBound..<source.endIndex))
        XCTAssertLessThan(gate.lowerBound, local.lowerBound)
        let release = try XCTUnwrap(source.range(of: "await gate.release()", range: local.upperBound..<source.endIndex))
        let networkGate = try XCTUnwrap(source.range(of: "await AttachmentThumbnailLoadGate.shared.acquire()", range: release.upperBound..<source.endIndex))
        let download = try XCTUnwrap(source.range(of: "await AttachmentThumbnailDiskCache.downloadImageResult", range: networkGate.upperBound..<source.endIndex))
        XCTAssertLessThan(local.lowerBound, release.lowerBound)
        XCTAssertLessThan(networkGate.lowerBound, download.lowerBound)
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        XCTAssertTrue(textBubbles.contains("maxPixelSize: Int((compact ? 30 : 34) * UIScreen.main.scale)"))
        XCTAssertTrue(mediaBubbles.contains("maxPixelSize: Int(max(displaySize.width, displaySize.height) * UIScreen.main.scale)"))
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
    }
    // WDT_CHAT_RESOURCE_PERF_20261023_END

    func testSliderVerificationPolicySupportsTrackDragThresholdAndReset() {
        XCTAssertEqual(SliderVerificationPolicy.clampedOffset(locationX: 0, width: 320), 0)
        XCTAssertEqual(SliderVerificationPolicy.clampedOffset(locationX: 320, width: 320), 270)
        XCTAssertFalse(SliderVerificationPolicy.completes(offset: 150, width: 320))
        XCTAssertTrue(SliderVerificationPolicy.completes(offset: 200, width: 320))
    }

    func testGroupMemberInviteAffordanceAllowsApprovalRequestWithoutGrantingManagement() {
        XCTAssertTrue(
            GroupMemberInviteAffordancePolicy.isVisible(
                canManage: true,
                inviteConfirmRequired: false
            ),
            "Owners and administrators can always invite members directly"
        )
        XCTAssertTrue(
            GroupMemberInviteAffordancePolicy.isVisible(
                canManage: false,
                inviteConfirmRequired: true,
                isMember: true
            ),
            "An ordinary member must be able to submit an invite for approval when approval is required"
        )
        XCTAssertTrue(
            GroupMemberInviteAffordancePolicy.isVisible(
                canManage: false,
                inviteConfirmRequired: false,
                isMember: true
            ),
            "Confirmed members can invite their friends even when approval is disabled"
        )
        XCTAssertFalse(GroupMemberInviteAffordancePolicy.isVisible(canManage: false, inviteConfirmRequired: true))
    }

    func testEnterpriseSwitcherDismissalFenceRequiresOneFreshSuccess() {
        var fence = EnterpriseSwitcherDismissalFence()

        fence.captureBaseline(7)

        XCTAssertFalse(fence.consume(successRevision: 7), "A failure or unchanged revision must keep the chooser visible")
        XCTAssertFalse(fence.consume(successRevision: 6), "A stale completion must not dismiss the chooser")
        XCTAssertTrue(fence.consume(successRevision: 8), "A fresh successful switch must dismiss the chooser")
        XCTAssertFalse(fence.consume(successRevision: 9), "The same chooser must dismiss at most once")
    }

    func testAvatarCropRendererProduces512PixelsFromThreeXSource() throws {
        let data = try Self.makeThreeXAvatarJPEG()
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)

        XCTAssertEqual(decoded.width, 512)
        XCTAssertEqual(decoded.height, 512)
        XCTAssertLessThanOrEqual(data.count, AvatarCropRenderer.maximumJPEGByteCount)
    }

    func testAvatarCropJPEGServerDecodeConfigurationIsExactly512Square() throws {
        let data = try Self.makeThreeXAvatarJPEG()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
    }

    func testAvatarRequestUsesInjectedRouteContextAndPreservesDirectAbsoluteSchemes() {
        let routeContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 7,
            routeHosts: ["tenant.example.test", "tenant-cf.example.test"]
        )
        let relative = "/api/tenant/static/avatars/default-user.webp"
        XCTAssertEqual(
            TenantRelativeImageURLResolver.request(relative, routeContext: routeContext),
            .tenantRelative(path: relative)
        )

        let directValues = [
            "https://cdn.example.test/avatar.webp?version=4",
            "https://tenant.example.test/api/tenant/avatar/current?signature=presigned",
            "data:image/png;base64,AAAA",
            "file:///tmp/avatar.png"
        ]
        for value in directValues {
            XCTAssertEqual(
                TenantRelativeImageURLResolver.request(value, routeContext: routeContext),
                .direct(urlString: value)
            )
        }
    }

    func testPersistedTenantAbsoluteAvatarMigratesOnlyForCurrentRouteHostAndQuerylessAvatarPath() {
        let routeContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 7,
            routeHosts: ["tenant.example.test", "tenant-cf.example.test"]
        )
        let stablePath = "/api/tenant/avatar/current"

        XCTAssertEqual(
            TenantRelativeImageURLResolver.request(
                "https://tenant.example.test\(stablePath)",
                routeContext: routeContext
            ),
            .tenantRelative(path: stablePath)
        )
        XCTAssertEqual(
            TenantRelativeImageURLResolver.request(
                "https://tenant.example.test:443\(stablePath)",
                routeContext: routeContext
            ),
            .tenantRelative(path: stablePath)
        )
        XCTAssertEqual(
            TenantRelativeImageURLResolver.request(
                "https://tenant-cf.example.test/api/tenant/static/avatars/default-user.webp",
                routeContext: routeContext
            ),
            .tenantRelative(path: "/api/tenant/static/avatars/default-user.webp")
        )

        let directValues = [
            "https://old-tenant.example.test\(stablePath)",
            "https://tenant.example.test:8443\(stablePath)",
            "https://user@tenant.example.test\(stablePath)",
            "http://tenant.example.test\(stablePath)",
            "https://tenant.example.test\(stablePath)?v=4",
            "https://tenant.example.test/api/tenant/files/object-1",
            "https://oss.example.test/avatar/object?token=opaque"
        ]
        for value in directValues {
            XCTAssertEqual(
                TenantRelativeImageURLResolver.request(value, routeContext: routeContext),
                .direct(urlString: value)
            )
        }
    }

    func testTenantRelativeAvatarCacheIdentityUsesStablePathVersionAndTenantScopeWithoutRouteHost() throws {
        let request = try XCTUnwrap(
            TenantRelativeImageURLResolver.request(
                "/api/tenant/avatar/current",
                routeContext: Self.makeRouteContext(
                    authorityID: "app-a|tenant-a",
                    revision: 7,
                    routeHosts: ["primary.example.test"]
                )
            )
        )
        let key = AvatarImageCache.cacheKey(
            url: request.stableIdentity,
            version: "version-42",
            updatedAt: "2026-08-12T00:00:00Z"
        )
        let primaryContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 7,
            routeHosts: ["primary.example.test"]
        )
        let failoverContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-a",
            revision: 8,
            routeHosts: ["cloudfront.example.test"]
        )
        let otherTenantContext = Self.makeRouteContext(
            authorityID: "app-a|tenant-b",
            revision: 7,
            routeHosts: ["primary.example.test"]
        )

        XCTAssertEqual(key, "/api/tenant/avatar/current#avatar_version=version-42")
        XCTAssertEqual(
            request.storageCacheKey(key, routeContext: primaryContext),
            request.storageCacheKey(key, routeContext: failoverContext)
        )
        XCTAssertNotEqual(
            request.storageCacheKey(key, routeContext: primaryContext),
            request.storageCacheKey(key, routeContext: otherTenantContext)
        )
        XCTAssertFalse(request.storageCacheKey(key, routeContext: primaryContext)?.contains("primary.example.test") == true)
        XCTAssertNotEqual(
            request.loadingTaskKey(
                try XCTUnwrap(request.storageCacheKey(key, routeContext: primaryContext)),
                routeContext: primaryContext
            ),
            request.loadingTaskKey(
                try XCTUnwrap(request.storageCacheKey(key, routeContext: failoverContext)),
                routeContext: failoverContext
            )
        )
    }

    func testAvatarUploadPresentationUsesCurrentTypedStageDespiteSanitizedOrThrottledToast() {
        let attempts: [(AvatarUploadResult, String)] = [
            (.failed(.presign, safeCode: "https://secret.example?token=presign", status: 500), "获取头像上传凭证失败，请重试"),
            (.failed(.put, safeCode: "signature-secret-token", status: 503), "头像图片上传失败，请重试"),
            (.failed(.commit, safeCode: "object-key-private", status: 422), "保存头像资料失败，请重试"),
            (.failed(.unknown, safeCode: "secret-token", status: 999), "头像上传失败，请稍后再试")
        ]

        for (result, expected) in attempts {
            let message = AvatarUploadFailurePresentation.message(for: result)
            XCTAssertEqual(message, expected)
            for forbiddenValue in ["https://", "?", "token", "signature", "object-key", "private", "secret", "500", "503", "422", "999"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(forbiddenValue))
            }
        }
        XCTAssertNotEqual(
            AvatarUploadFailurePresentation.message(for: attempts[1].0),
            AvatarUploadFailurePresentation.message(for: attempts[2].0)
        )
    }

    func testDefaultGroupAvatarURLRecognizesBackendStaticPlaceholder() {
        XCTAssertTrue(isDefaultGroupAvatarURL("http://localhost:8082/api/tenant/static/avatars/group-default-avatar-256.png"))
        XCTAssertTrue(isDefaultGroupAvatarURL("https://cdn.example.test/assets/default-group-avatar.png"))
        XCTAssertFalse(isDefaultGroupAvatarURL("http://localhost:8082/api/tenant/avatar/461f5f7c-7361-44b2-9e9e-393e27e5854b"))
        XCTAssertFalse(isDefaultGroupAvatarURL(""))
    }

    private static func makeThreeXAvatarJPEG() throws -> Data {
        let sourceFormat = UIGraphicsImageRendererFormat()
        sourceFormat.scale = 3
        sourceFormat.opaque = true
        let sourceSize = CGSize(width: 640, height: 480)
        let source = UIGraphicsImageRenderer(size: sourceSize, format: sourceFormat).image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: sourceSize))
            UIColor.systemTeal.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 120, y: 40, width: 400, height: 400))
        }
        XCTAssertEqual(source.scale, 3)

        return try XCTUnwrap(
            AvatarCropRenderer.croppedJPEG(
                image: source,
                previewSize: 282,
                outputPixelSize: 512,
                scale: 1.5,
                offset: CGSize(width: 18, height: -11)
            )
        )
    }

    func testChatSearchDatePickerUsesGregorianCalendarLabels() throws {
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        XCTAssertEqual(ChatSearchDatePurpose(keyword: " \n "), .jump)
        XCTAssertEqual(ChatSearchDatePurpose(keyword: "合同"), .filter)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        let selectedDate = try XCTUnwrap(ChatSearchCalendarSupport.date(year: 2026, month: 6, day: 27))

        XCTAssertEqual(ChatSearchCalendarSupport.monthTitle(for: selectedDate), "2026年6月")
        XCTAssertEqual(ChatSearchCalendarSupport.displayDate(selectedDate), "6月27日 周六")
        XCTAssertEqual(ChatSearchCalendarSupport.apiDate(selectedDate), "2026-06-27")
        XCTAssertFalse(ChatSearchCalendarSupport.monthTitle(for: selectedDate).contains("2569"))

        let cells = ChatSearchCalendarSupport.dayCells(
            for: selectedDate,
            selectedDate: selectedDate,
            today: selectedDate
        )
        let selectedCell = try XCTUnwrap(cells.first { $0.id == "2026-06-27" })
        XCTAssertTrue(selectedCell.isSelected)
        XCTAssertTrue(selectedCell.isToday)

        let futureCell = try XCTUnwrap(cells.first { $0.id == "2026-06-28" })
        XCTAssertTrue(futureCell.isFuture)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN

        let availability = ChatSearchCalendarSupport.dayCells(for: selectedDate, selectedDate: selectedDate,
            today: selectedDate, availableDates: [ChatSearchCalendarSupport.startOfDay(selectedDate)])
        XCTAssertEqual(availability.filter(\.isAvailable).map(\.id), ["2026-06-27"])
        XCTAssertEqual(availability.filter(\.isSelected).map(\.id), ["2026-06-27"])
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }

    func testChatSearchDismissalWaitsForFocusReleaseBeforeRemovingPanel() {
        var coordinator = ChatSearchDismissalCoordinator()

        XCTAssertEqual(coordinator.request(.close, isFocused: true), .releaseFocus)
        XCTAssertEqual(coordinator.pendingIntent, .close)
        XCTAssertEqual(coordinator.focusDidChange(isFocused: true), .none)
        XCTAssertEqual(coordinator.focusDidChange(isFocused: false), .dismissPanel)
        XCTAssertEqual(coordinator.consumePendingIntent(), .close)
        XCTAssertNil(coordinator.pendingIntent)
    }

    func testChatSearchDismissalCompletesImmediatelyWhenSearchIsNotFocused() {
        var coordinator = ChatSearchDismissalCoordinator()

        XCTAssertEqual(coordinator.request(.close, isFocused: false), .dismissPanel)
        XCTAssertEqual(coordinator.consumePendingIntent(), .close)
    }

    func testChatSearchDismissalPreservesSelectionIntentAndIgnoresDuplicateRequest() {
        var coordinator = ChatSearchDismissalCoordinator()

        XCTAssertEqual(coordinator.request(.selectResult, isFocused: true), .releaseFocus)
        XCTAssertEqual(coordinator.request(.close, isFocused: true), .none)
        XCTAssertEqual(coordinator.focusDidChange(isFocused: false), .dismissPanel)
        XCTAssertEqual(coordinator.consumePendingIntent(), .selectResult)
    }

    static func makePNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

}

// WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
private actor ThumbnailConcurrencyProbe {
    private var active = 0
    private var peak = 0
    private var completed = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }

    func snapshot() -> (active: Int, peak: Int, completed: Int) {
        (active, peak, completed)
    }
}
// WDT_CHAT_RESOURCE_PERF_20261023_END

// WDT_IOS1_IMAGE_BUDGET_20261023_BEGIN
private actor ConcurrencyImageTransport: RemoteImageTransporting {
    let data: Data
    private var running = 0
    private var peak = 0
    private var completed = 0
    init(data: Data) { self.data = data }
    func data(from url: URL) async throws -> RemoteImageTransportResult {
        running += 1
        peak = max(peak, running)
        defer { running -= 1; completed += 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        return RemoteImageTransportResult(data: data, statusCode: 200)
    }
    func snapshot() -> (running: Int, peak: Int, completed: Int) { (running, peak, completed) }
}
// WDT_IOS1_IMAGE_BUDGET_20261023_END
