import IM4Features
import SwiftUI
import UIKit

struct GroupProfileEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    @State private var groupName: String
    @State private var groupDescription: String
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var croppedAvatarData: Data?
    @State private var croppedPreview: UIImage?
    @State private var showCropper = false
    @State private var isSaving = false
    @State private var inlineMessage: String?

    private let outputSize = 512

    init(group: GroupInfo) {
        self.group = group
        _groupName = State(initialValue: group.name)
        _groupDescription = State(initialValue: group.groupDescription)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canSave: Bool {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = groupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionIsValid = GroupDescriptionInputPolicy.normalizedUnicodeScalarCount(groupDescription)
            <= GroupDescriptionInputPolicy.maximumUnicodeScalars
        let profileChanged = trimmed != currentGroup.name || croppedAvatarData != nil
        let descriptionChanged = normalizedDescription != currentGroup.groupDescription
        return !isSaving && !trimmed.isEmpty && descriptionIsValid && (profileChanged || descriptionChanged)
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: group.id) { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        GroupProfileEditContent(
            groupName: $groupName, groupDescription: $groupDescription,
            descriptionCount: GroupDescriptionInputPolicy.normalizedUnicodeScalarCount(groupDescription),
            hasCroppedAvatar: croppedAvatarData != nil, isSaving: isSaving,
            canSave: canSave, inlineMessage: inlineMessage, onClose: { dismiss() },
            onPickAvatar: { showPhotoPicker = true }, onSave: save
        ) {
            GroupAvatarView(name: groupName.isEmpty ? currentGroup.name : groupName, seed: 0x5D6BFF, size: 58, imageURL: croppedPreview == nil ? currentGroup.avatarURL : "", avatarVersion: croppedPreview == nil ? currentGroup.avatarVersion : "", avatarUpdatedAt: croppedPreview == nil ? currentGroup.avatarUpdatedAt : "", imageCacheKey: croppedPreview == nil ? state.groupAvatarCacheKey(groupID: currentGroup.id, avatarURL: currentGroup.avatarURL, avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt) : "")
                .overlay {
                    if let croppedPreview {
                        Image(uiImage: croppedPreview)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    }
                }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                // WDT_IOS1_AVATAR_MEMORY_20261023: downsample before any orientation redraw.
                guard let item = items.first,
                      let image = AvatarCropRenderer.sourceImage(data: item.data, fileURL: item.fileURL) else {
                    inlineMessage = "无法读取图片，请重新选择"
                    return
                }
                selectedImage = image.normalizedForGroupAvatarCrop()
                showCropper = true
            }
        }
        .sheet(isPresented: $showCropper, onDismiss: resetCropperSelection) {
            if let selectedImage {
                GroupAvatarCropperSheet(image: selectedImage) {
                    showCropper = false
                    resetCropperSelection()
                } onCropped: { data, preview in
                    croppedAvatarData = data
                    croppedPreview = preview
                    showCropper = false
                    resetCropperSelection()
                }
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
                .interactiveDismissDisabled(true)
            }
        }
    }

    private func resetCropperSelection() {
        selectedImage = nil
    }

    private func save() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            inlineMessage = "请输入群名称"
            return
        }
        guard !isSaving else { return }
        let normalizedDescription: String
        do {
            normalizedDescription = try GroupDescriptionInputPolicy.normalize(groupDescription)
        } catch let error as GroupDescriptionInputError {
            inlineMessage = error.userMessage
            return
        } catch {
            inlineMessage = "群描述格式不正确"
            return
        }
        let profileChanged = trimmedName != currentGroup.name || croppedAvatarData != nil
        let descriptionChanged = normalizedDescription != currentGroup.groupDescription
        isSaving = true
        inlineMessage = nil
        Task {
            var profileOK = true
            if profileChanged {
                profileOK = await state.updateGroupProfile(
                    groupID: currentGroup.id,
                    name: trimmedName,
                    avatarImageData: croppedAvatarData,
                    mimeType: "image/jpeg",
                    width: outputSize,
                    height: outputSize
                )
            }
            guard profileOK else {
                isSaving = false
                inlineMessage = state.toast ?? "群资料保存失败"
                return
            }
            var descriptionOK = true
            if descriptionChanged {
                descriptionOK = await state.updateGroupDescription(
                    groupID: currentGroup.id,
                    rawValue: normalizedDescription
                )
            }
            isSaving = false
            if descriptionOK {
                inlineMessage = "群资料已更新"
                dismiss()
            } else {
                inlineMessage = profileChanged
                    ? "名称或头像已保存，但群描述保存失败；请重试群描述"
                    : (state.toast ?? "群描述保存失败")
            }
        }
    }
}

private struct GroupAvatarCropperSheet: View {
    let image: UIImage
    let onClose: () -> Void
    let onCropped: (Data, UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    private let previewSize: CGFloat = 282
    private let outputSize = 512
    private let scaleRange: ClosedRange<CGFloat> = 1...4

    var body: some View {
        GroupAvatarCropContent(
            image: image, imageSize: image.normalizedForGroupAvatarCrop().size,
            previewSize: previewSize, scaleRange: scaleRange,
            onClose: {
                onClose()
                dismiss()
            },
            onCrop: { scale, offset in
                guard let result = croppedAvatar(scale: scale, offset: offset) else { return false }
                onCropped(result.data, result.preview)
                dismiss()
                return true
            }
        )
    }

    // WDT_IOS1_AVATAR_MEMORY_20261023_BEGIN
    private func croppedAvatar(scale: CGFloat, offset: CGSize) -> (data: Data, preview: UIImage)? {
        guard let data = AvatarCropRenderer.croppedJPEG(
            image: image,
            previewSize: previewSize,
            outputPixelSize: Int(outputSize),
            scale: scale,
            offset: offset,
            scaleRange: scaleRange
        ), let preview = RemoteImageDecoder.image(from: data, maxPixelSize: Int(outputSize)) else { return nil }
        return (data, preview)
    }
    // WDT_IOS1_AVATAR_MEMORY_20261023_END
}

private extension UIImage {
    // WDT_IOS1_AVATAR_MEMORY_20261023_BEGIN
    func normalizedForGroupAvatarCrop() -> UIImage {
        normalizedForAvatarCrop()
    }
    // WDT_IOS1_AVATAR_MEMORY_20261023_END
}
