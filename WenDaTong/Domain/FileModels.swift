// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain // WDT_IOS1_FILESTORE_COMPLETE_FAMILY_20261111

func mediaAttachmentDisplayName(_ fileName: String) -> String {
    let name = fileName as NSString
    return name.pathExtension.isEmpty ? fileName : name.deletingPathExtension
}

/// Local failure metadata only. Never retain error descriptions, request identifiers,
/// paths, URLs or arbitrary server values in a message/cache payload.

typealias FileItem = IM4Domain.FileItem

typealias VoiceFileListPolicy = IM4Domain.VoiceFileListPolicy

typealias FileUploadConfig = IM4Domain.FileUploadConfig


// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
