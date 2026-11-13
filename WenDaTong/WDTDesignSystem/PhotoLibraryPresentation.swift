// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct PhotoLibraryPickedItem: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let data: Data?
    public let fileURL: URL?
    public let sizeBytes: Int64?
    public let contentTypes: [UTType]

    public init(data: Data, contentTypes: [UTType]) {
        self.data = data
        fileURL = nil
        sizeBytes = Int64(data.count)
        self.contentTypes = contentTypes
    }

    public init(fileURL: URL, sizeBytes: Int64, contentTypes: [UTType]) {
        data = nil
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.contentTypes = contentTypes
    }
}

public enum PhotoLibraryPickerPresentation {
    @MainActor
    public static func makeController(
        selectionLimit: Int, filter: PHPickerFilter,
        bindDelegate: @MainActor (PHPickerViewController) -> Void
    ) -> PHPickerViewController {

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = selectionLimit
        configuration.filter = filter
        configuration.preferredAssetRepresentationMode = .current
        if #available(iOS 15.0, *) {
            configuration.selection = .ordered
        }
        let picker = PHPickerViewController(configuration: configuration)
        bindDelegate(picker)
        return picker
        }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
