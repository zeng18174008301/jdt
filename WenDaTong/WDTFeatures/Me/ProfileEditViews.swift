import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct NicknameEditSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var draftName = ""
    @State private var isSaving = false

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        NicknameEditContent(draftName: $draftName, nameCount: trimmedName.count, isSaving: isSaving,
            avatar: {
                AvatarView(name: draftName.isEmpty ? currentUserSnapshot.name : draftName, seed: currentUserSnapshot.avatarSeed, size: 48, imageURL: currentUserSnapshot.avatarURL, avatarVersion: currentUserSnapshot.avatarVersion, avatarUpdatedAt: currentUserSnapshot.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: currentUserSnapshot.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            }, onClose: { dismiss() }, onSave: saveNickname)
        .onAppear {
            draftName = state.currentUser.name
        }
    }

    private func saveNickname() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let ok = await state.updateCurrentUserProfile(name: trimmedName)
            await MainActor.run {
                isSaving = false
                if ok {
                    onSaved()
                }
            }
        }
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

struct UsernameEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var draftUsername = ""
    @State private var isSaving = false

    private var trimmedUsername: String {
        draftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidLength: Bool {
        (5...10).contains(trimmedUsername.count)
    }

    private var hasAllowedCharacters: Bool {
        !trimmedUsername.isEmpty && trimmedUsername.allSatisfy { ch in
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }
    }

    private var isValid: Bool {
        hasValidLength && hasAllowedCharacters
    }

    var body: some View {
        UsernameEditContent(draftUsername: $draftUsername, hasValidLength: hasValidLength,
            hasAllowedCharacters: hasAllowedCharacters, isValid: isValid, isSaving: isSaving,
            onClose: { dismiss() }, onSave: saveUsername)
        .onAppear {
            draftUsername = state.currentUser.username
        }
        .onChangeCompat(of: draftUsername) { _, newValue in
            let filtered = filteredUsername(newValue)
            if filtered != newValue {
                draftUsername = filtered
            }
        }
    }

    private func filteredUsername(_ value: String) -> String {
        String(value.filter { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }.prefix(10))
    }

    private func saveUsername() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let ok = await state.updateCurrentUserProfile(username: trimmedUsername)
            await MainActor.run {
                isSaving = false
                if ok {
                    onSaved()
                }
            }
        }
    }
}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct AvatarEditSheet: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var showCropper = false

    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        AvatarEditContent(avatar: {
            AvatarView(name: currentUserSnapshot.name, seed: currentUserSnapshot.avatarSeed, size: 58, imageURL: currentUserSnapshot.avatarURL, avatarVersion: currentUserSnapshot.avatarVersion, avatarUpdatedAt: currentUserSnapshot.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: currentUserSnapshot.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }, onClose: { dismiss() }, onChoosePhoto: { showPhotoPicker = true })
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                // WDT_IOS1_AVATAR_MEMORY_20261023: downsample before any orientation redraw.
                guard let item = items.first,
                      let image = AvatarCropRenderer.sourceImage(data: item.data, fileURL: item.fileURL) else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("无法读取图片")
                    return
                }
                selectedImage = image.normalizedForAvatarCrop()
                showCropper = true
            }
        }
        .sheet(isPresented: $showCropper, onDismiss: resetCropperSelection) {
            if let selectedImage {
                AvatarCropperView(
                    image: selectedImage,
                    onClose: {
                        showCropper = false
                        resetCropperSelection()
                    }
                ) {
                    showCropper = false
                    resetCropperSelection()
                    dismiss()
                }
                .environmentObject(state)
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
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

enum AvatarUploadFailurePresentation {
    static func message(for result: AvatarUploadResult) -> String {
        switch result.failureStage ?? .unknown {
        case .presign:
            return "获取头像上传凭证失败，请重试"
        case .put:
            return "头像图片上传失败，请重试"
        case .commit:
            return "保存头像资料失败，请重试"
        case .unknown:
            return "头像上传失败，请稍后再试"
        }
    }
}

enum AvatarCropRenderer {
    static let maximumJPEGByteCount = 2 * 1024 * 1024

    // WDT_IOS1_AVATAR_MEMORY_20261023_BEGIN
    nonisolated static func sourceImage(data: Data?, fileURL: URL?) -> UIImage? {
        if let fileURL {
            return RemoteImageDecoder.image(fromFileURL: fileURL, maxPixelSize: 2_048)
        }
        guard let data else { return nil }
        return RemoteImageDecoder.image(from: data, maxPixelSize: 2_048)
    }
    // WDT_IOS1_AVATAR_MEMORY_20261023_END

    static func croppedJPEG(
        image: UIImage,
        previewSize: CGFloat,
        outputPixelSize: Int,
        scale: CGFloat,
        offset: CGSize,
        scaleRange: ClosedRange<CGFloat> = 1...4
    ) -> Data? {
        guard previewSize > 0, outputPixelSize > 0 else { return nil }
        let normalized = image.normalizedForAvatarCrop()
        let imageSize = normalized.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let safeScale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        let safeOffset = AvatarCropBounds.clampedOffset(
            imageSize: imageSize,
            previewSize: previewSize,
            scale: safeScale,
            proposed: offset
        )
        let baseScale = max(previewSize / imageSize.width, previewSize / imageSize.height)
        let totalScale = max(baseScale * safeScale, 0.0001)
        let cropSide = min(imageSize.width, imageSize.height, previewSize / totalScale)
        var originX = imageSize.width / 2 - safeOffset.width / totalScale - cropSide / 2
        var originY = imageSize.height / 2 - safeOffset.height / totalScale - cropSide / 2
        originX = min(max(originX, 0), imageSize.width - cropSide)
        originY = min(max(originY, 0), imageSize.height - cropSide)
        let sourceScale = normalized.scale
        let cropRect = CGRect(
            x: originX * sourceScale,
            y: originY * sourceScale,
            width: cropSide * sourceScale,
            height: cropSide * sourceScale
        ).integral
        guard let cgImage = normalized.cgImage?.cropping(to: cropRect) else { return nil }
        let cropped = UIImage(cgImage: cgImage, scale: sourceScale, orientation: .up)

        let outputSize = CGSize(width: outputPixelSize, height: outputPixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let square = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            cropped.draw(in: CGRect(origin: .zero, size: outputSize))
        }

        var quality: CGFloat = 0.88
        var data = square.jpegData(compressionQuality: quality)
        while let current = data, current.count > maximumJPEGByteCount, quality > 0.40 {
            quality -= 0.08
            data = square.jpegData(compressionQuality: quality)
        }
        guard let data, data.count <= maximumJPEGByteCount else { return nil }
        return data
    }
}

private struct AvatarCropperView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let onClose: () -> Void
    let onUploaded: () -> Void

    @State private var isUploading = false
    @State private var inlineMessage: String?

    private let previewSize: CGFloat = 282
    private let outputSize = 512
    private let scaleRange: ClosedRange<CGFloat> = 1...4

    var body: some View {
        AvatarCropContent(image: image, imageSize: image.normalizedForAvatarCrop().size,
            previewSize: previewSize, scaleRange: scaleRange, isUploading: isUploading,
            inlineMessage: inlineMessage, onClose: {
                onClose()
                dismiss()
            }, onUpload: upload)
    }

    private func upload(scale: CGFloat, offset: CGSize) {
        guard !isUploading else { return }
        inlineMessage = nil
        guard let data = croppedAvatarData(scale: scale, offset: offset) else {
            inlineMessage = "头像裁剪失败，请重新选择图片"
            return
        }
        isUploading = true
        Task {
            let result = await state.uploadCurrentUserAvatarResult(
                imageData: data,
                mimeType: "image/jpeg",
                width: outputSize,
                height: outputSize
            )
            isUploading = false
            if result.success {
                inlineMessage = "头像上传成功"
                dismiss()
                onUploaded()
            } else {
                inlineMessage = AvatarUploadFailurePresentation.message(for: result)
            }
        }
    }

    private func croppedAvatarData(scale: CGFloat, offset: CGSize) -> Data? {
        AvatarCropRenderer.croppedJPEG(
            image: image,
            previewSize: previewSize,
            outputPixelSize: outputSize,
            scale: scale,
            offset: offset,
            scaleRange: scaleRange
        )
    }
}

extension UIImage {
    // WDT_IOS1_AVATAR_MEMORY_20261023_BEGIN
    func normalizedForAvatarCrop() -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest.isFinite, longest > 0 else { return self }
        guard imageOrientation != .up || longest > 2_048 else { return self }
        let ratio = min(1, 2_048 / longest)
        let outputSize = CGSize(width: max(1, pixelWidth * ratio), height: max(1, pixelHeight * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }
    // WDT_IOS1_AVATAR_MEMORY_20261023_END
}

private typealias ProfileEditSheetSurface<Content: View> = IM4Features.ProfileEditSheetSurface<Content>

private struct AvatarOptionRow: View {
    let title: String
    let subtitle: String
    let seed: UInt
    let selected: Bool
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: title, seed: seed, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(selected ? IMColor.success : IMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((selected ? IMColor.success : IMColor.brand).opacity(0.10)))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(selected ? 0.98 : 0.84))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(selected ? IMColor.success.opacity(0.36) : IMColor.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
