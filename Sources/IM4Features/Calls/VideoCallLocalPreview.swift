import Foundation
import SwiftUI
import IM4DesignSystem

struct VideoCallLocalPreviewLayout {
    let size: CGSize
    let contentInset: CGFloat
    private let bounds: CGRect

    init(available: CGSize) {
        let width = max(0, available.width)
        let height = max(0, available.height)
        let margin = min(12, min(width, height) / 4)
        let scale = min(1, min((width - 2 * margin) / 124, (height - 2 * margin) / 172))
        size = CGSize(width: 124 * scale, height: 172 * scale)
        contentInset = 3 * scale
        bounds = CGRect(
            x: margin + size.width / 2,
            y: margin + size.height / 2,
            width: max(0, width - 2 * margin - size.width),
            height: max(0, height - 2 * margin - size.height)
        )
    }

    func center(for point: CGPoint?, snapping: Bool = false) -> CGPoint {
        let proposed = point ?? CGPoint(x: bounds.maxX, y: bounds.minY)
        let x = min(max(proposed.x, bounds.minX), bounds.maxX)
        return CGPoint(
            x: snapping ? (x < bounds.midX ? bounds.minX : bounds.maxX) : x,
            y: min(max(proposed.y, bounds.minY), bounds.maxY)
        )
    }
}

struct SafeAreaDraggableLocalVideo<Local: View>: View {
    let mirrored: Bool
    let videoRegion: CGRect
    let renderer: (Bool) -> Local
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?

    private let coordinateSpaceName = "video-call-local-preview"

    var body: some View {
        let layout = VideoCallLocalPreviewLayout(available: videoRegion.size)
        renderer(mirrored)
            .padding(layout.contentInset)
            .frame(width: layout.size.width, height: layout.size.height)
            .background {
                RoundedRectangle(cornerRadius: layout.contentInset)
                    .strokeBorder(.white.opacity(0.75), lineWidth: min(2, layout.contentInset))
            }
            .overlay(alignment: .bottomLeading) {
                Text("我").font(.caption2.bold()).padding(5)
                    .foregroundStyle(.white).background(Color.black.opacity(0.55))
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .bottomLeading)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        let origin = dragOrigin ?? layout.center(for: center)
                        if dragOrigin == nil { dragOrigin = origin }
                        center = layout.center(for: CGPoint(x: origin.x + value.translation.width,
                                                           y: origin.y + value.translation.height))
                    }
                    .onEnded { value in
                        let origin = dragOrigin ?? layout.center(for: center)
                        center = layout.center(for: CGPoint(x: origin.x + value.translation.width,
                                                           y: origin.y + value.translation.height), snapping: true)
                        dragOrigin = nil
                    }
            )
            .onTapGesture { } // A preview tap never reaches the remote visibility gesture.
            .accessibilityLabel("本人视频小窗")
            .accessibilityHint("可在对方视频区域内拖动")
            .accessibilityAdjustableAction { direction in
                let point = layout.center(for: center)
                center = layout.center(for: CGPoint(x: point.x,
                    y: point.y + (direction == .increment ? 40 : -40)))
            }
            // Position the already interactive preview; the positioning region
            // must not become a gesture target covering the remote video.
            .position(layout.center(for: center))
            .frame(width: videoRegion.width, height: videoRegion.height, alignment: .topLeading)
            .coordinateSpace(name: coordinateSpaceName)
            .offset(x: videoRegion.minX, y: videoRegion.minY)
            .onChange(of: videoRegion) { _ in
                center = layout.center(for: center)
                dragOrigin = nil
            }
    }
}
