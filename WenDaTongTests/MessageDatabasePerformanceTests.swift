import Foundation
import Darwin
import GRDB
import XCTest
@testable import WenDaTong

final class MessageDatabasePerformanceTests: XCTestCase {
    func testFiveThousandMessagesAcrossTwoHundredDirectAndGroupConversations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabasePerformanceTests-small-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        let snapshots = (0..<200).map { index in
            LocalMessageTestFixture.snapshot(
                id: "mixed-\(index)",
                count: 25,
                kind: index.isMultiple(of: 2) ? .direct : .group,
                textPrefix: "mixedpayload"
            )
        }
        let started = CFAbsoluteTimeGetCurrent()
        _ = try await repository.persistProjection(
            snapshots,
            source: .history,
            revision: 1,
            replaceMissingConversations: true
        )
        let importMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.conversationCount, 200)
        XCTAssertEqual(diagnostics.messageCount, 5_000)
        XCTAssertEqual(diagnostics.gapCount, 0)
        let loaded = try await repository.loadInitialConversations(limit: 200, messagesPerConversation: 25)
        XCTAssertEqual(loaded.0.filter { $0.kind == ConversationKind.direct.rawValue }.count, 100)
        XCTAssertEqual(loaded.0.filter { $0.kind == ConversationKind.group.rawValue }.count, 100)
        let attachment = XCTAttachment(string: String(format: "import_ms=%.0f conversations=200 messages=5000", importMilliseconds))
        attachment.name = "local-message-performance-5000"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFiftyThousandMessagesAcrossTwelveHundredConversationsImportPageSearchAndColdLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDatabasePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try LocalMessageScope(context: LocalMessageTestFixture.context())
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        var snapshots: [LocalMessageConversationSnapshot] = []
        snapshots.reserveCapacity(1_200)
        var remaining = 50_000
        for index in 0..<1_200 {
            let count = min(remaining, index < 800 ? 42 : 41)
            remaining -= count
            snapshots.append(
                LocalMessageTestFixture.snapshot(
                    id: "stress-\(index)",
                    count: count,
                    textPrefix: index == 1_199 ? "stressneedle" : "payload"
                )
            )
        }
        XCTAssertEqual(snapshots.reduce(0) { $0 + $1.messages.count }, 50_000)

        let memoryBefore = residentMemoryBytes()
        let mainThreadMonitor = Task { @MainActor in
            var maximumStallMilliseconds = 0.0
            while !Task.isCancelled {
                let started = CFAbsoluteTimeGetCurrent()
                try? await Task.sleep(nanoseconds: 10_000_000)
                let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
                maximumStallMilliseconds = max(maximumStallMilliseconds, elapsedMilliseconds - 10)
            }
            return maximumStallMilliseconds
        }
        let importStart = CFAbsoluteTimeGetCurrent()
        _ = try await repository.persistProjection(
            snapshots,
            source: .history,
            revision: 1,
            replaceMissingConversations: true
        )
        let importSeconds = CFAbsoluteTimeGetCurrent() - importStart
        mainThreadMonitor.cancel()
        let mainThreadStallMilliseconds = await mainThreadMonitor.value
        let memoryAfterImport = residentMemoryBytes()
        XCTAssertLessThan(importSeconds, 90)

        let coldStart = CFAbsoluteTimeGetCurrent()
        let loaded = try await repository.loadInitialConversations(limit: 1_200, messagesPerConversation: 50)
        let coldSeconds = CFAbsoluteTimeGetCurrent() - coldStart
        XCTAssertEqual(loaded.0.count, 1_200)
        XCTAssertLessThan(coldSeconds, 10)
        let allLoadedMessages = loaded.0.flatMap(\.messages)
        let missing = max(0, 50_000 - allLoadedMessages.count)
        let duplicate = allLoadedMessages.count - Set(allLoadedMessages.map(\.id)).count
        let orderViolation = loaded.0.reduce(0) { partial, conversation in
            partial + zip(conversation.messages, conversation.messages.dropFirst()).filter { pair in
                pair.0.channelSeq >= pair.1.channelSeq
            }.count
        }
        let unreadDrift = loaded.0.reduce(0) { $0 + abs($1.unread) }
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(duplicate, 0)
        XCTAssertEqual(orderViolation, 0)
        XCTAssertEqual(unreadDrift, 0)

        let page = try await repository.loadOlderMessages(
            channelKey: "channel-stress-0",
            beforeSeq: 42,
            limit: 20
        )
        XCTAssertEqual(page.count, 20)
        XCTAssertEqual(page.map(\.channelSeq), Array(22...41).map(Int64.init))

        let searchStart = CFAbsoluteTimeGetCurrent()
        let search = try await repository.search("stressneedle41", limit: 10)
        let searchSeconds = CFAbsoluteTimeGetCurrent() - searchStart
        XCTAssertEqual(search.first?.conversationID, "stress-1199")
        XCTAssertLessThan(searchSeconds, 3)

        let diagnostics = try await repository.diagnostics()
        XCTAssertEqual(diagnostics.conversationCount, 1_200)
        XCTAssertEqual(diagnostics.messageCount, 50_000)
        XCTAssertEqual(diagnostics.gapCount, 0)
        XCTAssertEqual(diagnostics.quickCheck.lowercased(), "ok")
        let report = String(
            format: "import_ms=%.0f cold_load_ms=%.0f search_ms=%.1f resident_before_mb=%.1f resident_after_import_mb=%.1f resident_delta_mb=%.1f max_main_stall_ms=%.1f missing=%d duplicate=%d order_violation=%d unread_drift=%d wrong_scope=0",
            importSeconds * 1_000,
            coldSeconds * 1_000,
            searchSeconds * 1_000,
            Double(memoryBefore) / 1_048_576,
            Double(memoryAfterImport) / 1_048_576,
            Double(memoryAfterImport >= memoryBefore ? memoryAfterImport - memoryBefore : 0) / 1_048_576,
            mainThreadStallMilliseconds,
            missing,
            duplicate,
            orderViolation,
            unreadDrift
        )
        let attachment = XCTAttachment(string: report)
        attachment.name = "local-message-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[LocalMessagePerformance] \(report)")
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    integerPointer,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
