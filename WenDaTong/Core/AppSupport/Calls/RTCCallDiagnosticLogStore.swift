import AVFoundation
import Foundation
import IM4Data // WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111

// WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: keep system call frameworks out unless a build explicitly enables CallKit.
#if WDT_ENABLE_CALLKIT && canImport(CallKit)
@preconcurrency import CallKit
#endif

#if WDT_ENABLE_CALLKIT && canImport(PushKit)
@preconcurrency import PushKit
#endif
// WDT_IOS1_CALLKIT_CN_POLICY_20260923_END

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

actor RTCCallDiagnosticLogStore {
    static let shared = RTCCallDiagnosticLogStore()

    private static let maxLogBytes: UInt64 = 2_000_000
    private static let maxLineCharacters = 2_400

    private let fileStorage: IM4Data.RotatingLogFileStorage
    private let exportDirectoryURL: URL
    private let timestampFormatter: ISO8601DateFormatter
    private var sequence: UInt64 = 0

    // The optional base isolates direct consumer tests; the production singleton keeps its original paths.
    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        let baseURL = baseURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("RTCCallDiagnostics", isDirectory: true)
        self.fileStorage = IM4Data.RotatingLogFileStorage(
            fileManager: fileManager, directoryURL: directoryURL,
            logURL: directoryURL.appendingPathComponent("rtc-call-diagnostics.log"),
            previousLogURL: directoryURL.appendingPathComponent("rtc-call-diagnostics.previous.log")
        )
        self.exportDirectoryURL = fileManager.temporaryDirectory
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = formatter
    }

    func append(category: String, media: String? = nil, callID: String? = nil, message: String, at date: Date = Date()) {
        do {
            try fileStorage.prepareForAppend(maximumBytes: Self.maxLogBytes)
            sequence += 1
            let normalizedCategory = sanitizeField(category)
            let normalizedMedia = normalizeMedia(media)
            let normalizedCallID = sanitizeField(callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let callComponent = normalizedCallID.isEmpty ? "" : " call=\(normalizedCallID)"
            let line = "\(timestampFormatter.string(from: date)) seq=\(sequence) media=\(normalizedMedia) [\(normalizedCategory)]\(callComponent) \(sanitizeMessage(message))\n"
            guard let data = line.data(using: .utf8) else { return }
            try fileStorage.append(data)
        } catch {
            // Diagnostics must never affect call behavior.
        }
    }

    func makeExportTextFile() throws -> URL {
        try fileStorage.prepareForRead()
        let generatedAt = Date()
        let exportURL = exportDirectoryURL
            .appendingPathComponent("rtc-call-diagnostics-\(exportStamp(for: generatedAt)).txt")
        var contents = exportHeader(generatedAt: generatedAt)
        var hasLogContent = false
        if let previousLog = fileStorage.previousText(), !previousLog.isEmpty {
            contents += "\n# Previous rotated log\n"
            contents += previousLog
            hasLogContent = true
        }
        if let currentLog = fileStorage.currentText(), !currentLog.isEmpty {
            contents += "\n# Current log\n"
            contents += currentLog
            hasLogContent = true
        }
        if !hasLogContent {
            contents += "\nNo RTC call diagnostic lines recorded yet.\n"
        }
        try fileStorage.writeAtomically(Data(contents.utf8), to: exportURL)
        return exportURL
    }

    private func exportHeader(generatedAt: Date) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "问达通"
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        return """
        # \(displayName) RTC Call Diagnostics
        generated_at=\(timestampFormatter.string(from: generatedAt))
        bundle_id=\(bundleID)
        app_version=\(version)
        build=\(build)
        file_format=txt
        media_legend=voice:语音通话, video:视频通话, unknown:共享/系统链路
        note=Short identifiers and redacted diagnostic events only. RTC tokens are not written by this logger.

        """
    }

    private func exportStamp(for date: Date) -> String {
        timestampFormatter
            .string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func sanitizeField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeMedia(_ value: String?) -> String {
        let normalized = sanitizeField(value ?? "").lowercased()
        switch normalized {
        case "voice", "audio":
            return "voice"
        case "video":
            return "video"
        default:
            return "unknown"
        }
    }

    private func sanitizeMessage(_ message: String) -> String {
        var sanitized = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(
            of: "(?i)(authorization|bearer|token|rtcToken)[=: ]+[^\\s]+",
            with: "$1=<redacted>",
            options: .regularExpression
        )
        if sanitized.count > Self.maxLineCharacters {
            return String(sanitized.prefix(Self.maxLineCharacters)) + "...[truncated]"
        }
        return sanitized
    }
}
