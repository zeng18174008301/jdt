import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

public struct ChatAttachmentSelectionInput: Identifiable {
    public let id: UUID
    public let name: String
    public let mediaCategory: String
    public let mimeType: String
    public let effectiveSizeBytes: Int64
    public let previewImage: UIImage?
    var typeTitle: String {
        switch mediaCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        default: return mimeType.isEmpty ? "普通文件" : mimeType
        }
    }

    public var symbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }



    public init(id: UUID,
        name: String,
        mediaCategory: String,
        mimeType: String,
        effectiveSizeBytes: Int64,
        previewImage: UIImage? = nil) {
        self.id = id
        self.name = name
        self.mediaCategory = mediaCategory
        self.mimeType = mimeType
        self.effectiveSizeBytes = effectiveSizeBytes
        self.previewImage = previewImage
    }
}
public struct ChatAttachmentConfirmationInput: Identifiable {
    public let id: UUID
    public let totalSizeBytes: Int64
    public let selections: [ChatAttachmentSelectionInput]
    public var isMultiple: Bool { selections.count > 1 }
    public var photoCount: Int { selections.filter { $0.mediaCategory == "image" }.count }
    public var videoCount: Int { selections.filter { $0.mediaCategory == "video" }.count }
    public var title: String {
        guard isMultiple else { return "发送附件" }
        if photoCount == selections.count {
            return "发送照片"
        }
        if videoCount == selections.count {
            return "发送视频"
        }
        return "发送附件"
    }

    public var subtitle: String {
        guard isMultiple else { return "确认名称、类型和大小后再上传发送。" }
        if photoCount == selections.count {
            return "共 \(photoCount) 张照片，确认后按队列发送。"
        }
        if videoCount == selections.count {
            return "共 \(videoCount) 个视频，确认后按队列发送。"
        }
        if photoCount > 0 {
            return "共 \(selections.count) 个附件，含 \(photoCount) 张照片，确认后按队列发送。"
        }
        return "共 \(selections.count) 个附件，确认后按队列发送。"
    }

    var confirmTitle: String {
        isMultiple ? "确认发送 \(selections.count) 个" : "确认发送"
    }



    public init(id: UUID,
        totalSizeBytes: Int64,
        selections: [ChatAttachmentSelectionInput]) {
        self.id = id
        self.totalSizeBytes = totalSizeBytes
        self.selections = selections
    }
}
public struct ChatAnnouncementActions {
    public let load: () -> Void
    public let reload: (String) -> Void
    public let copy: (String) -> Void
    public let emptyContent: () -> Void
    public let publish: (String, String, @escaping (Bool) -> Void) -> Bool

    public init(load: @escaping () -> Void,
        reload: @escaping (String) -> Void,
        copy: @escaping (String) -> Void,
        emptyContent: @escaping () -> Void,
        publish: @escaping (String, String, @escaping (Bool) -> Void) -> Bool) {
        self.load = load
        self.reload = reload
        self.copy = copy
        self.emptyContent = emptyContent
        self.publish = publish
    }
}
public struct ChatForwardInput {
    public let draft: ChatForwardDraftPresentation?
    public let targets: [BatchForwardTargetCandidate]
    public let canForward: Bool
    public let selectedKeys: Set<String>
    public let avatarCacheKeys: [String: String]
    public let certifications: [String: ChatCertificationRendering.Reference]

    public init(draft: ChatForwardDraftPresentation? = nil,
        targets: [BatchForwardTargetCandidate],
        canForward: Bool,
        selectedKeys: Set<String>,
        avatarCacheKeys: [String: String],
        certifications: [String: ChatCertificationRendering.Reference]) {
        self.draft = draft
        self.targets = targets
        self.canForward = canForward
        self.selectedKeys = selectedKeys
        self.avatarCacheKeys = avatarCacheKeys
        self.certifications = certifications
    }
}
public struct ChatForwardActions {
    public let submit: () -> Void
    public let search: (String) -> Void
    public let tab: (BatchForwardTargetTab) -> Void
    public let remove: (String) -> Void
    public let toggle: (BatchForwardTarget) -> Void

    public init(submit: @escaping () -> Void,
        search: @escaping (String) -> Void,
        tab: @escaping (BatchForwardTargetTab) -> Void,
        remove: @escaping (String) -> Void,
        toggle: @escaping (BatchForwardTarget) -> Void) {
        self.submit = submit
        self.search = search
        self.tab = tab
        self.remove = remove
        self.toggle = toggle
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

public struct ChatReactionLifecycleInput: Equatable {
    public let authenticated: Bool
    public let originalTaskKey: String
    public let bindingGeneration: UUID
    public let sessionGeneration: UInt64
    public let sessionEpoch: String
    public let authoritySessionID: String

    public init(authenticated: Bool,
        originalTaskKey: String,
        bindingGeneration: UUID,
        sessionGeneration: UInt64,
        sessionEpoch: String,
        authoritySessionID: String) {
        self.authenticated = authenticated
        self.originalTaskKey = originalTaskKey
        self.bindingGeneration = bindingGeneration
        self.sessionGeneration = sessionGeneration
        self.sessionEpoch = sessionEpoch
        self.authoritySessionID = authoritySessionID
    }
}

public func chatForwardTargetCertificationUID(
        for candidate: BatchForwardTargetCandidate, actor: String?
    ) -> String {
        guard !candidate.isGroup else { return "" }
        let actorUID = actor?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = candidate.target.channelID
            .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "|" })
            .map {
                String($0).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
        if parts.count == 2, !actorUID.isEmpty {
            let actorMatches = parts.filter { $0 == actorUID }
            guard actorMatches.count == 1 else { return "" }
            return parts.first(where: { $0 != actorUID }) ?? ""
        }
        let directUID = candidate.target.channelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actorUID.isEmpty,
              parts.count == 1,
              directUID == parts[0],
              directUID != actorUID else {
            return ""
        }
        return directUID
    }
