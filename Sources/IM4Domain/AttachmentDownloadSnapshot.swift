// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_BEGIN
import Foundation

public struct AttachmentDownloadSnapshot: Equatable, Sendable {
    public init(receivedBytes: Int64 = 0, totalBytes: Int64? = nil, isCommitting: Bool = false) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.isCommitting = isCommitting
    }
    var receivedBytes: Int64 = 0
    var totalBytes: Int64? = nil
    public var isCommitting = false

    public var fraction: Double? {
        guard !isCommitting, let totalBytes, totalBytes > 0, receivedBytes < totalBytes else { return nil }
        return max(0, Double(receivedBytes) / Double(totalBytes))
    }

    public var label: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        if isCommitting || (totalBytes.map { $0 > 0 && receivedBytes >= $0 } ?? false) { return "校验/保存中" }
        if let totalBytes, let fraction {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(Int(fraction * 100))% · \(received)/\(total)"
        }
        return "已下载 \(received)"
    }
}
// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_END
