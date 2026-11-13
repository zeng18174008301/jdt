// WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111
import IM4Domain
import IM4Stores

typealias AttachmentDownloadSnapshot = IM4Domain.AttachmentDownloadSnapshot
typealias FileStore = IM4Stores.FileStore

// The single original App construction remains FileStore(); only App owns file deletion.
extension IM4Stores.FileStore {
    convenience init() {
        self.init(removeOwnedPendingUpload: { $0.removeOwnedFile() })
    }
}
