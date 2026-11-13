import CryptoKit
import Foundation
import ImageIO
import UIKit
import XCTest
@testable import WenDaTong

extension MediaPipelineTests {
    func testGIFFallbackDecodesExactColorsTransparencyAndDisposalTwoAndThree() throws {
        let original = try publicTransparentGIFFixture()
        let metadata = try StickerGIFFallbackDecoder.metadata(data: original)
        XCTAssertEqual(metadata.width, 4)
        XCTAssertEqual(metadata.height, 2)
        XCTAssertEqual(metadata.frameCount, 2)
        let first = try StickerGIFFallbackDecoder.frame(data: original, index: 0, maxPixelSize: 4)
        let second = try StickerGIFFallbackDecoder.frame(data: original, index: 1, maxPixelSize: 4)
        XCTAssertEqual(try fallbackBGRA(first, x: 0, y: 0), [0, 0, 128, 255])
        XCTAssertEqual(try fallbackBGRA(first, x: 2, y: 1), [0, 0, 224, 255])
        XCTAssertEqual(try fallbackBGRA(second, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(try fallbackBGRA(second, x: 2, y: 1), [0, 0, 224, 255], "transparent overlay must preserve the red pixel beneath")
        XCTAssertEqual(try fallbackBGRA(second, x: 3, y: 1), [85, 0, 0, 255])
        XCTAssertEqual(first.delay, 0.1, accuracy: 0.001)
        XCTAssertEqual(second.delay, 0.2, accuracy: 0.001)

        for disposal in [UInt8(2), 3] {
            let data = try publicTransparentGIFFixture(disposal: disposal)
            XCTAssertEqual(try StickerGIFFallbackDecoder.metadata(data: data).frameCount, 3)
            let beforeDisposal = try StickerGIFFallbackDecoder.frame(data: data, index: 1, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(beforeDisposal, x: 1, y: 1), [255, 0, 0, 255])
            let third = try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(third, x: 0, y: 0), [0, 0, 16, 255])
            XCTAssertEqual(try fallbackBGRA(third, x: 0, y: 1), [0, 0, 192, 255], "disposal must not clear pixels outside the previous frame rectangle")
            for x in 1...3 {
                let expected: [UInt8] = disposal == 2 ? [0, 0, 0, 0] : [0, 0, UInt8(192 + x * 16), 255]
                XCTAssertEqual(try fallbackBGRA(third, x: x, y: 1), expected, "disposal=\(disposal), x=\(x)")
            }
            let rereadFirst = try StickerGIFFallbackDecoder.frame(data: data, index: 0, maxPixelSize: 4)
            XCTAssertEqual(try fallbackBGRA(rereadFirst, x: 0, y: 0), [0, 0, 128, 255], "random access must not retain a later composite")
        }
    }

    func testGIFFallbackBoundsOutputAndRejectsTruncatedForgedAndOversizedInputs() throws {
        let wide = try makeGIFFixture(frameCount: 2, width: 1100, height: 2)
        for index in [0, 1] {
            let decoded = try StickerGIFFallbackDecoder.frame(data: wide, index: index, maxPixelSize: 5000)
            let image = try XCTUnwrap(decoded.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.height, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        let valid = try publicTransparentGIFFixture()
        var badLZW = valid
        badLZW[127] = 12 // GIF LZW minimum code size cannot exceed 8.
        for invalid in [Data(valid.prefix(20)), Data(valid.prefix(160)), Data("GIF89a forged image".utf8), badLZW] {
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: invalid, index: 1, maxPixelSize: 4))
        }
        XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: valid, index: -1, maxPixelSize: 4))
        XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: valid, index: 2, maxPixelSize: 4))
        var giantCanvas = valid
        giantCanvas[6] = 0x01; giantCanvas[7] = 0x10 // 4097 × 4096 exceeds 16 Mi source pixels.
        giantCanvas[8] = 0x00; giantCanvas[9] = 0x10
        var oversizedBody = valid
        oversizedBody.append(Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1 - valid.count))
        for oversized in [giantCanvas, oversizedBody] {
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.metadata(data: oversized)) {
                XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
            }
            XCTAssertThrowsError(try StickerGIFFallbackDecoder.frame(data: oversized, index: 0, maxPixelSize: 4)) {
                XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
            }
        }
    }

    func testGIFFallbackCancelledTaskCannotReturnFrameAndNextDecodeStillWorks() async throws {
        let data = try publicTransparentGIFFixture(disposal: 3)
        let gate = GIFTestDataGate()
        let task = Task.detached {
            await gate.wait()
            return try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("a cancelled decode must not publish a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let next = try StickerGIFFallbackDecoder.frame(data: data, index: 2, maxPixelSize: 4)
        XCTAssertEqual(try fallbackBGRA(next, x: 1, y: 1), [0, 0, 208, 255])
    }

    func testGIFDecoderPreservesAllFramesBeyondSeventyTwoAndLongDelay() async throws {
        let data = try makeGIFFixture(frameCount: 80, delay: 0.7)
        let decoder = try StickerGIFImageDecoder(data: data, maxPixelSize: 32, requiresGIF: true)
        let frameCount = await decoder.frameCount
        XCTAssertEqual(frameCount, 80)
        let first = try await decoder.frame(at: 0)
        let last = try await decoder.frame(at: 79)
        XCTAssertNotEqual(first.image.pngData(), last.image.pngData())
        XCTAssertEqual(last.delay, 0.7, accuracy: 0.011)
        let repeatedFirst = try await decoder.frame(at: 0)
        XCTAssertEqual(first.image.pngData(), repeatedFirst.image.pngData())
    }

    func testGIFDecoderBoundsPixelsAndRejectsOversizedLogicalCanvasBeforeDecode() async throws {
        let data = try makeGIFFixture(frameCount: 1, width: 1100, height: 2)
        let decoder = try StickerGIFImageDecoder(data: data, maxPixelSize: 5000, requiresGIF: true)
        let frame = try await decoder.frame(at: 0)
        let image = try XCTUnwrap(frame.image.cgImage)
        XCTAssertLessThanOrEqual(image.width, 1024)
        XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        var oversizedCanvas = try makeGIFFixture(frameCount: 1)
        oversizedCanvas[6] = 0xff
        oversizedCanvas[7] = 0xff
        oversizedCanvas[8] = 0xff
        oversizedCanvas[9] = 0xff
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: oversizedCanvas, maxPixelSize: 32, requiresGIF: true)) {
            XCTAssertEqual($0 as? StickerGIFResourceError, .tooLarge)
        }
    }

    func testGIFDecoderKeepsStaticStickerCompatibilityButRejectsMislabeledGIF() async throws {
        let png = try XCTUnwrap(UIImage(cgImage: makeGIFFrame(width: 2, height: 2, blue: false)).pngData())
        let decoder = try StickerGIFImageDecoder(data: png, maxPixelSize: 32)
        let frameCount = await decoder.frameCount
        XCTAssertEqual(frameCount, 1)
        _ = try await decoder.frame(at: 0)
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: png, maxPixelSize: 32, requiresGIF: true))
        XCTAssertThrowsError(try StickerGIFImageDecoder(data: Data("not an image".utf8), maxPixelSize: 32))
    }

    @MainActor
    func testGIFPlaybackLimiterCountsInstancesNotSharedAssetKeysAndReleases() {
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<5).map { _ in UUID() }
        for player in players.prefix(4) { XCTAssertTrue(limiter.acquire(player)) }
        XCTAssertTrue(limiter.acquire(players[0]))
        XCTAssertEqual(limiter.activePlayers.count, 4)
        XCTAssertFalse(limiter.acquire(players[4]))
        limiter.release(players[0])
        XCTAssertTrue(limiter.acquire(players[4]))
        for player in players { limiter.release(player) }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
    }

    @MainActor
    func testGIFFifthVisiblePlayerGetsFirstFrameAndExplicitPlaybackPriority() async throws {
        let bytes = try makeGIFFixture(frameCount: 2, width: 16, height: 16)
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<5).map { _ in UUID() }
        var loaders: [StickerGIFFrameLoader] = []
        for (index, player) in players.enumerated() {
            limiter.setVisible(player, true)
            let loader = StickerGIFFrameLoader { _ in bytes }
            await loader.load(url: URL(string: "https://gif.example.test/\(index).gif"), cacheKey: "asset-\(index)", maxPixelSize: 16, requiresGIF: true, retainDecoder: false)
            XCTAssertNotNil(loader.frame)
            XCTAssertFalse(loader.retainsDecoder)
            limiter.requestAnimation(player, eligible: true)
            loaders.append(loader)
        }
        XCTAssertEqual(limiter.activePlayers.count, 4)
        XCTAssertFalse(limiter.activePlayers.contains(players[4]))
        XCTAssertNotNil(loaders[4].frame, "Animation saturation must not suppress the fifth first frame")
        limiter.prioritize(players[4])
        XCTAssertTrue(limiter.activePlayers.contains(players[4]))
        let prepared = await loaders[4].prepareForPlayback()
        XCTAssertTrue(prepared)
        let advanced = await loaders[4].showFrame(at: 1)
        XCTAssertTrue(advanced)
        XCTAssertEqual(loaders[4].currentFrameIndex, 1)
        loaders[4].releaseAnimation()
        XCTAssertFalse(loaders[4].retainsDecoder)
        XCTAssertNotNil(loaders[4].frame)
        XCTAssertEqual(loaders[4].currentFrameIndex, 0)
        for (player, loader) in zip(players, loaders) {
            loader.stop()
            limiter.setVisible(player, false)
            XCTAssertNil(loader.frame)
        }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
        XCTAssertTrue(limiter.visiblePlayers.isEmpty)
    }

    @MainActor
    func testGIFFailedStaticAndPowerRestrictedPlayersDoNotHoldAnimationSlots() async throws {
        let animated = try makeGIFFixture(frameCount: 2)
        let still = try XCTUnwrap(UIImage(cgImage: makeGIFFrame(width: 2, height: 2, blue: false)).pngData())
        for restriction in ["failed", "static", "reduceMotion", "lowPower"] {
            let limiter = StickerGIFPlaybackLimiter()
            let players = (0..<5).map { _ in UUID() }
            for (index, player) in players.enumerated() {
                limiter.setVisible(player, true)
                let restricted = index < 4
                let bytes = restricted && restriction == "failed" ? Data("invalid".utf8)
                    : restricted && restriction == "static" ? still : animated
                let loader = StickerGIFFrameLoader { _ in bytes }
                await loader.load(url: URL(string: "https://gif.example.test/item"), cacheKey: "item", maxPixelSize: 16, retainDecoder: false)
                let eligible = StickerGIFPlaybackEligibility.allowsAnimation(visible: true, frameCount: loader.frameCount,
                    failed: loader.failed, reduceMotion: restricted && restriction == "reduceMotion", lowPower: restricted && restriction == "lowPower")
                limiter.requestAnimation(player, eligible: eligible)
                if restricted { XCTAssertFalse(limiter.activePlayers.contains(player), restriction) }
                if restriction != "failed" || !restricted { XCTAssertNotNil(loader.frame) }
                XCTAssertFalse(loader.retainsDecoder)
                loader.stop()
            }
            XCTAssertEqual(limiter.activePlayers, Set([players[4]]), restriction)
            limiter.requestAnimation(players[0], eligible: true)
            XCTAssertTrue(limiter.activePlayers.contains(players[0]), "Power/static state recovery may acquire a free slot")
        }
    }

    @MainActor
    func testGIFFullscreenPriorityAndVisiblePreviewMemoryBudget() {
        let limiter = StickerGIFPlaybackLimiter()
        let players = (0..<48).map { _ in UUID() }
        for player in players { limiter.setVisible(player, true) }
        let limit = limiter.previewPixelLimit(requested: 1024)
        XCTAssertLessThanOrEqual(players.count * limit * limit * 4, StickerGIFPlaybackLimiter.previewBudgetBytes)
        for player in players.prefix(4) { limiter.requestAnimation(player, eligible: true) }
        limiter.requestAnimation(players[4], eligible: true, priority: true)
        XCTAssertTrue(limiter.activePlayers.contains(players[4]))
        XCTAssertEqual(limiter.activePlayers.count, 4)
        limiter.setVisible(players[4], false)
        XCTAssertEqual(limiter.activePlayers, Set(players.prefix(4)))
        for player in players { limiter.setVisible(player, false) }
        XCTAssertTrue(limiter.activePlayers.isEmpty)
        XCTAssertEqual(limiter.previewPixelLimit(requested: 1024), 1024)
    }

    func testGIFHighResolutionUploadCandidateDecodesFirstAndLaterFramesWithinBudget() async throws {
        let bytes = try autoreleasepool { try makeGIFFixture(frameCount: 2, width: 2560, height: 1920) }
        XCTAssertLessThan(bytes.count, Int(GIFAttachmentUploadPolicy.maximumBytes))
        XCTAssertTrue(try GIFAttachmentUploadPolicy.isGIF(data: bytes, fileURL: nil, name: "normal-high-resolution.gif", mimeType: "image/gif"))
        let decoder = try StickerGIFImageDecoder(data: bytes, maxPixelSize: 1024, requiresGIF: true)
        let first = try await decoder.frame(at: 0)
        let later = try await decoder.frame(at: 1)
        for frame in [first, later] {
            let image = try XCTUnwrap(frame.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        XCTAssertNotEqual(first.image.pngData(), later.image.pngData())
        XCTAssertEqual(StickerGIFImageDecoder.maximumSourcePixels * 3 * 4, StickerGIFImageDecoder.maximumCompositeWorkingBytes)
    }

    func testGIFTexturedHighResolutionUploadCandidateDecodesFirstAndLaterFrames() async throws {
        let bytes = try autoreleasepool { try makeGIFFixture(frameCount: 2, width: 2560, height: 1920, textured: true) }
        XCTAssertLessThan(bytes.count, Int(GIFAttachmentUploadPolicy.maximumBytes))
        XCTAssertTrue(try GIFAttachmentUploadPolicy.isGIF(data: bytes, fileURL: nil, name: "high-resolution.gif", mimeType: "image/gif"))
        let decoder = try StickerGIFImageDecoder(data: bytes, maxPixelSize: 1024, requiresGIF: true)
        let first = try await decoder.frame(at: 0)
        let later = try await decoder.frame(at: 1)
        for frame in [first, later] {
            let image = try XCTUnwrap(frame.image.cgImage)
            XCTAssertEqual(image.width, 1024)
            XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, StickerGIFImageDecoder.maximumFrameBytes)
        }
        XCTAssertNotEqual(first.image.pngData(), later.image.pngData())
    }

    @MainActor
    func testGIFLatePlaybackPreparationCannotRestoreDecoderAfterPauseOrOffscreenStop() async throws {
        let bytes = try makeGIFFixture(frameCount: 2)
        for offscreen in [false, true] {
            let gate = GIFTestDataGate()
            let counter = GIFTestReadCounter()
            let loader = StickerGIFFrameLoader { _ in
                if await counter.next() > 1 { await gate.wait() }
                return bytes
            }
            await loader.load(url: URL(string: "https://gif.example.test/a.gif"), cacheKey: "a", maxPixelSize: 16, requiresGIF: true, retainDecoder: false)
            let preparation = Task { await loader.prepareForPlayback() }
            await gate.waitUntilStarted()
            if offscreen { loader.stop() } else { loader.releaseAnimation() }
            await gate.release()
            let prepared = await preparation.value
            XCTAssertFalse(prepared)
            XCTAssertFalse(loader.retainsDecoder)
            XCTAssertFalse(loader.failed)
            if offscreen { XCTAssertNil(loader.frame) } else { XCTAssertNotNil(loader.frame) }
        }
    }

    func testGIFViewportRejectsOffscreenAndZeroViewportWithoutHistoryScanning() {
        let viewport = CGRect(x: 0, y: 50, width: 300, height: 500)
        XCTAssertTrue(StickerGIFVisibility.intersects(frame: CGRect(x: 10, y: 40, width: 30, height: 30), viewport: viewport))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: CGRect(x: 10, y: 550, width: 30, height: 30), viewport: viewport))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: viewport, viewport: .zero))
        XCTAssertFalse(StickerGIFVisibility.intersects(frame: .null, viewport: viewport))
    }

    @MainActor
    func testGIFLoaderURLPixelAndGenerationFenceRejectLateLoadAfterReuseAndStop() async throws {
        let gate = GIFTestDataGate()
        let data = try makeGIFFixture(frameCount: 2, width: 16, height: 16)
        let loader = StickerGIFFrameLoader { url in
            if url.lastPathComponent == "old.gif" { await gate.wait() }
            return data
        }
        let oldURL = URL(string: "https://gif.example.test/old.gif")!
        let newURL = URL(string: "https://gif.example.test/new.gif")!
        let oldLoad = Task { await loader.load(url: oldURL, cacheKey: "same-asset", maxPixelSize: 16, requiresGIF: true) }
        await gate.waitUntilStarted()
        await loader.load(url: newURL, cacheKey: "same-asset", maxPixelSize: 4, requiresGIF: true)
        XCTAssertEqual(loader.loadedIdentity?.url, newURL)
        XCTAssertEqual(loader.loadedIdentity?.maxPixelSize, 4)
        XCTAssertEqual(loader.frame?.image.cgImage?.width, 4)
        await gate.release()
        await oldLoad.value
        XCTAssertEqual(loader.loadedIdentity?.url, newURL)
        XCTAssertEqual(loader.frame?.image.cgImage?.width, 4)
        loader.stop()
        XCTAssertNil(loader.frame)
        XCTAssertNil(loader.loadedIdentity)
        XCTAssertEqual(loader.frameCount, 0)
        XCTAssertFalse(loader.failed)
    }

    @MainActor
    func testGIFLoaderStopCancelsAndDropsLateCompletion() async throws {
        let gate = GIFTestDataGate()
        let data = try makeGIFFixture(frameCount: 2)
        let loader = StickerGIFFrameLoader { _ in await gate.wait(); return data }
        let load = Task { await loader.load(url: URL(string: "https://gif.example.test/a.gif"), cacheKey: "a", maxPixelSize: 32) }
        await gate.waitUntilStarted()
        loader.stop()
        await gate.release()
        await load.value
        XCTAssertNil(loader.frame)
        XCTAssertNil(loader.loadedIdentity)
        XCTAssertEqual(loader.frameCount, 0)
        XCTAssertFalse(loader.failed)
    }

    @MainActor
    func testGIFLoaderRecoversSignedURLOnlyOnceAndSupportsMissingPrimary() async throws {
        let data = try makeGIFFixture(frameCount: 2)
        let attempts = LockedInteger()
        let loader = StickerGIFFrameLoader { _ in
            if attempts.incrementAndGetPrevious() == 0 { throw StickerGIFResourceError.unauthorized }
            return data
        }
        var recoveryCount = 0
        await loader.load(url: URL(string: "https://gif.example.test/expired.gif"), cacheKey: "a", maxPixelSize: 32) {
            recoveryCount += 1
            return URL(string: "https://gif.example.test/fresh.gif")
        }
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(attempts.value(), 2)
        XCTAssertEqual(loader.frameCount, 2)
        let denied = StickerGIFFrameLoader { _ in throw StickerGIFResourceError.unauthorized }
        recoveryCount = 0
        await denied.load(url: nil, cacheKey: "b", maxPixelSize: 32) {
            recoveryCount += 1
            return URL(string: "https://gif.example.test/denied.gif")
        }
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertTrue(denied.failed)
    }

    func testGIFResourceReaderRejectsHTTPFailuresAndUnboundedBodies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaPipelineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://gif.example.test/a.gif")!
        for (status, expected) in [(403, StickerGIFResourceError.unauthorized), (500, .invalidResponse)] {
            MediaPipelineURLProtocol.reset(statusCode: status, data: Data())
            do { _ = try await StickerGIFResourceReader.read(url, session: session); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? StickerGIFResourceError, expected) }
        }
        MediaPipelineURLProtocol.reset(statusCode: 200, data: Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1))
        do { _ = try await StickerGIFResourceReader.read(url, session: session); XCTFail("Oversized streamed body accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .tooLarge) }
        let gif = try makeGIFFixture(frameCount: 2)
        MediaPipelineURLProtocol.reset(statusCode: 200, data: gif)
        let result = try await StickerGIFResourceReader.read(url, session: session)
        XCTAssertEqual(result, gif)
    }

    func testGIFResourceReaderBoundsLocalFilesAndRejectsUnsupportedTransport() async throws {
        let root = makeCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("too-large.gif")
        try Data(repeating: 0, count: StickerGIFResourceReader.maximumBytes + 1).write(to: url)
        do { _ = try await StickerGIFResourceReader.read(url); XCTFail("Oversized local file accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .tooLarge) }
        do { _ = try await StickerGIFResourceReader.read(URL(string: "ftp://gif.example.test/a.gif")!); XCTFail("Unsupported transport accepted") }
        catch { XCTAssertEqual(error as? StickerGIFResourceError, .invalidTransport) }
    }

    private func publicTransparentGIFFixture(disposal: UInt8? = nil) throws -> Data {
        // Source: google/wuffs test/data/artificial-gif/transparent-index.gif
        // https://github.com/google/wuffs/blob/main/test/data/artificial-gif/transparent-index.gif
        // Copyright The Wuffs Authors; Apache-2.0 (see bundled Wuffs license).
        // The original 165-byte fixture has a 4x2 red frame and a 3x1 blue overlay
        // whose middle pixel is transparent. Derived variants change only frame 2's
        // disposal bits and append a one-pixel third frame to observe disposal.
        var data = try XCTUnwrap(Data(base64Encoded: "R0lGODlhBAACAIQAAAAAABAAACAAADAAAEAAAFAAAGAAAHAAAIAAAJAAAKAAALAAAMAAANAAAOAAAPAAAAAAAAAAEQAAIgAAMwAARAAAVQAAZgAAdwAAiAAAmQAAqgAAuwAAzAAA3QAA7gAA/yH5BAAKAAAALAAAAAAEAAIAAAcJCAkKCwwNDg+BACH5BAEUABoALAEAAQADAAEAAAcEHxoVgQA7"))
        if let disposal {
            XCTAssertTrue(disposal == 2 || disposal == 3)
            XCTAssertEqual(Array(data[139...142]), [0x21, 0xf9, 0x04, 0x01])
            data[142] = 0x01 | (disposal << 2)
            XCTAssertEqual(data.removeLast(), 0x3b)
            data.append(contentsOf: [
                0x21, 0xf9, 4, 0, 30, 0, 0, 0, // GCE, 300 ms, keep frame.
                0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, // One pixel at (0, 0).
                7, 2, 1, 0x81, 0, 0x3b // Literal palette index 1, LZW end, trailer.
            ])
        }
        return data
    }

    private func fallbackBGRA(_ frame: StickerGIFDecodedFrame, x: Int, y: Int) throws -> [UInt8] {
        let image = try XCTUnwrap(frame.image.cgImage)
        XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
        XCTAssertTrue(image.bitmapInfo.contains(.byteOrder32Little))
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let start = y * image.bytesPerRow + x * 4
        guard x >= 0, y >= 0, x < image.width, y < image.height, start + 4 <= bytes.count else {
            XCTFail("pixel coordinate outside decoded buffer")
            return []
        }
        return Array(bytes[start..<(start + 4)])
    }

    private func makeGIFFrame(width: Int, height: Int, blue: Bool, textured: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if textured {
            for y in stride(from: 0, to: height, by: 16) {
                for x in stride(from: 0, to: width, by: 16) {
                    let shade = (x / 16 + y / 16 * 7 + (blue ? 5 : 0)) % 64
                    context.setFillColor(red: CGFloat(shade % 4) / 3, green: CGFloat(shade / 4 % 4) / 3, blue: CGFloat(shade / 16) / 3, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: 16, height: 16))
                }
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeGIFFixture(frameCount: Int, width: Int = 2, height: Int = 2, delay: Double = 0.1, textured: Bool = false) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frameCount, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frameCount {
            let frame = try makeGIFFrame(width: width, height: height, blue: !index.isMultiple(of: 2), textured: textured)
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor GIFTestReadCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor GIFTestDataGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
