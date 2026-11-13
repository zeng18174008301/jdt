import Foundation
import IM4Domain
import IM4Stores

typealias ConversationStore = IM4Stores.ConversationStore
typealias ConversationSelectionEpochFence = IM4Stores.ConversationSelectionEpochFence
typealias ConversationUserLookup = IM4Domain.ConversationUserLookup

func textRemovingGroupMemberTotals(_ raw: String) -> String {
    IM4Domain.textRemovingGroupMemberTotals(raw)
}

extension ConversationStore {
    convenience init(messageSyncEngine: any SyncEngine = DefaultSyncEngine(), scope: LocalMessageScope? = nil) {
        self.init(syncEngine: messageSyncEngine, scope: scope,
            rtcAuthorities: ConversationMemoryRTCPolicy.rtcAuthorities,
            rtcAuthority: RTCCallRecordMessageDeduplicator.authority,
            conversationListPreview: { $0.conversationListPreview },
            normalizeRTCRecords: { RealtimeConversationReducer(conversations: []).conversationsEnforcingGlobalRTCCallRecordExactOnce($0) },
            recordLagDiagnostic: { line in
#if DEBUG
                DebugConsoleDiagnostics.trace(line)
                ConversationListLagTraceRecorder.record(line)
#endif
            })
    }

    func performMemoryCommand<Result>(presentationPageID: UUID? = nil,
        realtimeSignposts: [RealtimeMessageFlowSignpost], _ operation: () throws -> Result) rethrows -> Result {
        try performMemoryCommand(presentationPageID: presentationPageID,
            memoryDiagnostics: realtimeSignposts.map { $0.memoryDiagnostic() }, operation)
    }
}

#if DEBUG
private actor ConversationListLagTraceWriter {
    static let shared = ConversationListLagTraceWriter()

    private let fileURL: URL
    private let maxBytes = 512 * 1024
    private var didAnnounceFile = false

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        fileURL = directory.appendingPathComponent("conversation-list-lag.log", isDirectory: false)
    }

    func append(_ line: String) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(fileManager: fileManager)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let payload = Data("\(timestamp) \(line)\n".utf8)
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(payload)
            handle.closeFile()
            if !didAnnounceFile {
                didAnnounceFile = true
                DebugConsoleDiagnostics.trace("[JHT Perf] conversation_list_lag_log_file path=\(fileURL.path)")
            }
        } catch {
            DebugConsoleDiagnostics.trace("[JHT Perf] conversation_list_lag_log_file_failed error=\(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        try? fileManager.removeItem(at: fileURL)
    }
}

enum ConversationListLagTraceRecorder {
    static func record(_ line: String) {
        Task.detached(priority: .utility) {
            await ConversationListLagTraceWriter.shared.append(line)
        }
    }
}
#endif
