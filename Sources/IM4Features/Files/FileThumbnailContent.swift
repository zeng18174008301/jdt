// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct FileThumbnailContent<ImageRenderer: View, VideoRenderer: View>: View {
    let size: CGFloat
    let accentHex: UInt
    let kind: FileVisualKind
    let thumbnailURL: URL?
    let videoFrameURL: URL?
    let image: (URL, FileThumbnailTypeLogo) -> ImageRenderer
    let video: (URL, FileThumbnailTypeLogo) -> VideoRenderer

    public init(size: CGFloat, accentHex: UInt, kind: FileVisualKind, thumbnailURL: URL?, videoFrameURL: URL?,
                @ViewBuilder image: @escaping (URL, FileThumbnailTypeLogo) -> ImageRenderer,
                @ViewBuilder video: @escaping (URL, FileThumbnailTypeLogo) -> VideoRenderer) {
        self.size = size
        self.accentHex = accentHex
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.videoFrameURL = videoFrameURL
        self.image = image
        self.video = video
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(im4Hex: accentHex).opacity(0.12))

            if let thumbnailURL = thumbnailURL {
                image(thumbnailURL, fileTypeLogo)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if kind == .video, let videoFrameURL = videoFrameURL {
                video(videoFrameURL, fileTypeLogo)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                fileTypeLogo
            }

            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.48)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.66), lineWidth: 1)
        )
    }

    private var fileTypeLogo: FileThumbnailTypeLogo {
        FileThumbnailTypeLogo(kind: kind, accentHex: accentHex)
    }
}

public struct FileThumbnailTypeLogo: View {
    let kind: FileVisualKind
    let accentHex: UInt

    public var body: some View {
        VStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color(im4Hex: accentHex))
            Text(kind.shortLabel)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(Color(im4Hex: accentHex).opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(6)
    }

}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
