// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import IM4DesignSystem
import UniformTypeIdentifiers

typealias PhotoLibraryPickedItem = IM4DesignSystem.PhotoLibraryPickedItem

extension PhotoLibraryPickedItem {
    init(file: PendingAttachmentFile, contentTypes: [UTType]) {
        self.init(fileURL: file.url, sizeBytes: file.sizeBytes, contentTypes: contentTypes)
    }
}

struct PhotoLibraryPickerCompat: UIViewControllerRepresentable {
    let selectionLimit: Int
    let filter: PHPickerFilter
    let onPicked: ([PhotoLibraryPickedItem]) -> Void
    let prefersFileBackedItems: Bool
    let onCancel: () -> Void

    init(
        selectionLimit: Int,
        filter: PHPickerFilter,
        prefersFileBackedItems: Bool = false,
        onCancel: @escaping () -> Void = {},
        onPicked: @escaping ([PhotoLibraryPickedItem]) -> Void
    ) {
        self.selectionLimit = selectionLimit
        self.filter = filter
        self.prefersFileBackedItems = prefersFileBackedItems
        self.onCancel = onCancel
        self.onPicked = onPicked
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        IM4DesignSystem.PhotoLibraryPickerPresentation.makeController(selectionLimit: selectionLimit, filter: filter) {
            $0.delegate = context.coordinator
        }
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPickerCompat

        init(parent: PhotoLibraryPickerCompat) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }
            Task {
                let items = await Self.loadItems(
                    from: results,
                    prefersFileBackedItems: parent.prefersFileBackedItems
                )
                await MainActor.run {
                    parent.onPicked(items)
                }
            }
        }

        private static func loadItems(
            from results: [PHPickerResult],
            prefersFileBackedItems: Bool
        ) async -> [PhotoLibraryPickedItem] {
            var loaded: [PhotoLibraryPickedItem] = []
            // JHT_MOD_BEGIN CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改开始：记录多选读取结果，定位选择 9 张只进入部分发送队列
            for (index, result) in results.enumerated() {
                if let item = await loadItem(
                    from: result.itemProvider,
                    prefersFileBackedItems: prefersFileBackedItems
                ) {
                    loaded.append(item)
                } else {
                    #if DEBUG
                    print("[JHT PhotoPicker] item_load_failed index=\(index) identifiers=\(result.itemProvider.registeredTypeIdentifiers.count) prefers_file=\(prefersFileBackedItems)")
                    #endif
                }
            }
            #if DEBUG
            let fileBackedCount = loaded.filter { $0.fileURL != nil }.count
            let dataBackedCount = loaded.filter { $0.data != nil }.count
            print("[JHT PhotoPicker] load_finished requested=\(results.count) loaded=\(loaded.count) file_backed=\(fileBackedCount) data_backed=\(dataBackedCount) prefers_file=\(prefersFileBackedItems)")
            #endif
            // JHT_MOD_END CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改结束
            return loaded
        }

        private static func loadItem(
            from provider: NSItemProvider,
            prefersFileBackedItems: Bool
        ) async -> PhotoLibraryPickedItem? {
            let preferredIdentifiers = preferredTypeIdentifiers(from: provider.registeredTypeIdentifiers)
            let gifIdentifiers = preferredIdentifiers.filter { UTType($0)?.conforms(to: .gif) == true }
            // A provider's JPEG/PNG fallback is often only the first GIF frame.
            let identifiers = gifIdentifiers.isEmpty ? preferredIdentifiers : gifIdentifiers
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                let contentTypes = [identifier].compactMap(UTType.init)
                // JHT_MOD_BEGIN CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改开始：聊天附件优先使用临时文件；文件表示失败时兜底读取 data，避免多选图片被静默丢弃
                if prefersFileBackedItems,
                   let file = try? await loadManagedFile(
                    from: provider,
                    typeIdentifier: identifier
                   ) {
                    return PhotoLibraryPickedItem(file: file, contentTypes: contentTypes)
                }
                // JHT_MOD_END CHAT_PHOTO_PICKER_FILE_FALLBACK_20260914 - 修改结束
                guard let data = try? await loadItemData(from: provider, typeIdentifier: identifier),
                      !data.isEmpty else {
                    continue
                }
                return PhotoLibraryPickedItem(data: data, contentTypes: contentTypes)
            }
            return nil
        }

        private static func loadManagedFile(
            from provider: NSItemProvider,
            typeIdentifier: String
        ) async throws -> PendingAttachmentFile {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                        return
                    }
                    do {
                        let type = UTType(typeIdentifier)
                        var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if name.isEmpty {
                            name = type?.conforms(to: .movie) == true ? "视频消息" : "图片消息"
                        }
                        if (name as NSString).pathExtension.isEmpty,
                           let fileExtension = type?.preferredFilenameExtension {
                            name += ".\(fileExtension)"
                        }
                        continuation.resume(returning: try PendingAttachmentFileStore.stageFile(
                            from: url,
                            preferredName: name
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private static func loadItemData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            if let data = try? await loadData(from: provider, typeIdentifier: typeIdentifier),
               !data.isEmpty {
                return data
            }
            return try await loadFileData(from: provider, typeIdentifier: typeIdentifier)
        }

        private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
            }
        }

        private static func loadFileData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        do {
                            continuation.resume(returning: try Data(contentsOf: url))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
            }
        }

        private static func preferredTypeIdentifiers(from identifiers: [String]) -> [String] {
            let preferred = identifiers.sorted { lhs, rhs in
                priority(for: lhs) < priority(for: rhs)
            }
            return preferred.isEmpty ? identifiers : preferred
        }

        private static func priority(for identifier: String) -> Int {
            guard let type = UTType(identifier) else { return 100 }
            if type.conforms(to: .gif) { return 0 }
            if type.conforms(to: .png) { return 1 }
            if type.conforms(to: .jpeg) { return 2 }
            if type.conforms(to: .movie) { return 3 }
            if type.conforms(to: .image) { return 4 }
            return 10
        }
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
