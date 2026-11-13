import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@MainActor
final class RTCVideoRenderRegistry: ObservableObject {
    static let shared = RTCVideoRenderRegistry()

    @Published private(set) var localRevision = 0
    @Published private(set) var remoteRevision = 0

    private var localTrack: RTCVideoTrack?
    private var remoteTrack: RTCVideoTrack?
    private var localRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]
    private var remoteRenderers: [ObjectIdentifier: RTCVideoRenderer] = [:]

    func setLocalTrack(_ track: RTCVideoTrack?) {
        if let old = localTrack {
            localRenderers.values.forEach { old.remove($0) }
        }
        localTrack = track
        if let track {
            localRenderers.values.forEach { track.add($0) }
        }
        localRevision &+= 1
    }

    func setRemoteTrack(_ track: RTCVideoTrack?) {
        if let old = remoteTrack {
            remoteRenderers.values.forEach { old.remove($0) }
        }
        remoteTrack = track
        if let track {
            remoteRenderers.values.forEach { track.add($0) }
        }
        remoteRevision &+= 1
    }

    func attach(_ renderer: RTCVideoRenderer, local: Bool) {
        let key = ObjectIdentifier(renderer as AnyObject)
        if local {
            localRenderers[key] = renderer
            localTrack?.add(renderer)
        } else {
            remoteRenderers[key] = renderer
            remoteTrack?.add(renderer)
        }
    }

    func detach(_ renderer: RTCVideoRenderer, local: Bool) {
        let key = ObjectIdentifier(renderer as AnyObject)
        if local {
            localTrack?.remove(renderer)
            localRenderers.removeValue(forKey: key)
        } else {
            remoteTrack?.remove(renderer)
            remoteRenderers.removeValue(forKey: key)
        }
    }

    func clear() {
        setLocalTrack(nil)
        setRemoteTrack(nil)
    }
}

struct RTCVideoRendererView: UIViewRepresentable {
    let local: Bool
    var mirrored = false
    var onVideoSizeChanged: ((CGSize) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(local: local, onVideoSizeChanged: onVideoSizeChanged)
    }

    func makeUIView(context: Context) -> RTCVideoRendererContainer {
        let container = RTCVideoRendererContainer()
        container.renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.renderer = container.renderer
        container.renderer.delegate = context.coordinator
        RTCVideoRenderRegistry.shared.attach(container.renderer, local: local)
        return container
    }

    func updateUIView(_ uiView: RTCVideoRendererContainer, context: Context) {
        context.coordinator.onVideoSizeChanged = onVideoSizeChanged
        uiView.renderer.videoContentMode = .scaleAspectFit
        uiView.renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ uiView: RTCVideoRendererContainer, coordinator: Coordinator) {
        coordinator.active = false
        uiView.renderer.delegate = nil
        RTCVideoRenderRegistry.shared.detach(uiView.renderer, local: coordinator.local)
    }

    @MainActor
    final class Coordinator: NSObject, RTCVideoViewDelegate {
        let local: Bool
        weak var renderer: RTCMTLVideoView?
        var active = true
        var onVideoSizeChanged: ((CGSize) -> Void)?
        private var lastSize = CGSize.zero

        init(local: Bool, onVideoSizeChanged: ((CGSize) -> Void)?) {
            self.local = local
            self.onVideoSizeChanged = onVideoSizeChanged
        }

        nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            // Copy identity at the delegate boundary; the non-Sendable renderer
            // must not cross into the main actor with the callback.
            let rendererID = ObjectIdentifier(videoView as AnyObject)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active,
                      self.renderer.map(ObjectIdentifier.init) == rendererID,
                      size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0,
                      size != self.lastSize else { return }
                self.lastSize = size
                self.onVideoSizeChanged?(size)
            }
        }
    }
}

// SwiftUI owns the viewport; decoded frame dimensions must never become its
// intrinsic layout size. RTCMTLVideoView fits the rotated frame inside this box.
final class RTCVideoRendererContainer: UIView {
    let renderer = RTCMTLVideoView(frame: .zero)

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        renderer.backgroundColor = .black
        renderer.videoContentMode = .scaleAspectFit
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(renderer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Changing bounds/center is safe while the local camera is mirrored.
        renderer.bounds = CGRect(origin: .zero, size: bounds.size)
        renderer.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

#else
struct RTCVideoRendererView: View {
    let local: Bool
    var mirrored = false
    var onVideoSizeChanged: ((CGSize) -> Void)?

    var body: some View {
        Color.black
    }
}
#endif
