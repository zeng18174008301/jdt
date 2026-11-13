// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_BEGIN
import Foundation

/// Synchronous file mechanics. The existing caller owns serialization, paths and log policy.
public struct RotatingLogFileStorage {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let logURL: URL
    private let previousLogURL: URL

    public init(fileManager: FileManager = .default, directoryURL: URL, logURL: URL, previousLogURL: URL) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.logURL = logURL
        self.previousLogURL = previousLogURL
    }

    public func prepareForAppend(maximumBytes: UInt64) throws {
        try prepareDirectory()
        try rotateLogIfNeeded(maximumBytes: maximumBytes)
        ensureLogFileExists()
    }

    public func prepareForRead() throws {
        try prepareDirectory()
        ensureLogFileExists()
    }

    public func append(_ data: Data) throws {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    }

    public func previousText() -> String? { logText(from: previousLogURL) }
    public func currentText() -> String? { logText(from: logURL) }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func ensureLogFileExists() {
        guard !fileManager.fileExists(atPath: logURL.path) else { return }
        fileManager.createFile(atPath: logURL.path, contents: nil)
    }

    private func rotateLogIfNeeded(maximumBytes: UInt64) throws {
        guard currentLogSize() >= maximumBytes else { return }
        if fileManager.fileExists(atPath: previousLogURL.path) {
            try? fileManager.removeItem(at: previousLogURL)
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: previousLogURL)
        }
    }

    private func currentLogSize() -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func logText(from url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
// WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111_END
