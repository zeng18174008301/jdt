// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import Foundation

public enum FileVisualKind: Equatable {
    case image
    case video
    case pdf
    case spreadsheet
    case word
    case presentation
    case archive
    case audio
    case text
    case unknown

    public var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .pdf: "doc.richtext.fill"
        case .spreadsheet: "tablecells.fill"
        case .word: "doc.text.fill"
        case .presentation: "rectangle.on.rectangle.angled"
        case .archive: "archivebox.fill"
        case .audio: "waveform"
        case .text: "text.document.fill"
        case .unknown: "doc.fill"
        }
    }

    public var shortLabel: String {
        switch self {
        case .image: "IMG"
        case .video: "VID"
        case .pdf: "PDF"
        case .spreadsheet: "XLS"
        case .word: "DOC"
        case .presentation: "PPT"
        case .archive: "ZIP"
        case .audio: "AUD"
        case .text: "TXT"
        case .unknown: "FILE"
        }
    }

    public var title: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        case .pdf: "PDF 文档"
        case .spreadsheet: "表格"
        case .word: "文档"
        case .presentation: "演示文稿"
        case .archive: "压缩包"
        case .audio: "音频"
        case .text: "文本"
        case .unknown: "附件"
        }
    }

    public var previewTitle: String {
        switch self {
        case .image: "查看"
        case .video: "播放"
        case .pdf, .spreadsheet, .word, .presentation, .text: "系统预览"
        default: "预览"
        }
    }

    public var previewSymbol: String {
        switch self {
        case .video: "play.fill"
        case .pdf, .spreadsheet, .word, .presentation, .text: "doc.viewfinder"
        case .image: "photo.on.rectangle.angled"
        default: "eye.fill"
        }
    }

    public var canUseSystemPreview: Bool {
        switch self {
        case .image, .video, .pdf, .spreadsheet, .word, .presentation, .text:
            true
        case .archive, .audio, .unknown:
            false
        }
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
