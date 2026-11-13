import Foundation
import SwiftUI
import IM4DesignSystem

struct VideoCallPreviewControlPresentation: Equatable, Sendable {
    let cameraTitle: String
    let cameraSystemImage: String
    let cameraControlEnabled: Bool
    let startTitle: String

    static func resolve(
        cameraEnabled: Bool,
        isPreparing: Bool,
        isStartingCall: Bool,
        unavailableReason: String?
    ) -> Self {
        let cameraUnavailable = !(unavailableReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        return Self(
            cameraTitle: cameraUnavailable
                ? "摄像头不可用"
                : (cameraEnabled ? "关闭摄像头" : "开启摄像头"),
            cameraSystemImage: cameraUnavailable || !cameraEnabled
                ? "video.slash.fill"
                : "video.fill",
            cameraControlEnabled: !cameraUnavailable && !isPreparing && !isStartingCall,
            startTitle: isStartingCall
                ? "正在发起…"
                : (cameraUnavailable ? "关闭摄像头继续" : "开始呼叫")
        )
    }
}

public struct VideoCallPreviewInput: Sendable {
    let peerName: String
    let cameraEnabled: Bool
    let isPreparing: Bool
    let isStartingCall: Bool
    let unavailableReason: String?
    let startError: String?
    public init(peerName: String, cameraEnabled: Bool, isPreparing: Bool, isStartingCall: Bool, unavailableReason: String?, startError: String?) {
        self.peerName = peerName
        self.cameraEnabled = cameraEnabled
        self.isPreparing = isPreparing
        self.isStartingCall = isStartingCall
        self.unavailableReason = unavailableReason
        self.startError = startError
    }
}

public struct VideoCallPreviewContent<Local: View, Certification: View>: View {
    let input: VideoCallPreviewInput
    let localRenderer: () -> Local
    let certification: () -> Certification
    let onCancel: () -> Void
    let onToggleCamera: () -> Void
    let onStart: () -> Void
    public init(input: VideoCallPreviewInput, @ViewBuilder localRenderer: @escaping () -> Local,
                @ViewBuilder certification: @escaping () -> Certification,
                onCancel: @escaping () -> Void, onToggleCamera: @escaping () -> Void,
                onStart: @escaping () -> Void) {
        self.input = input; self.localRenderer = localRenderer; self.certification = certification
        self.onCancel = onCancel; self.onToggleCamera = onToggleCamera; self.onStart = onStart
    }
    private var controlPresentation: VideoCallPreviewControlPresentation {
        .resolve(cameraEnabled: input.cameraEnabled, isPreparing: input.isPreparing,
                 isStartingCall: input.isStartingCall, unavailableReason: input.unavailableReason)
    }
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("取消") { onCancel() }
                        .foregroundStyle(.white)
                    Spacer()
                    VStack(spacing: 3) {
                        Text("呼叫 \(input.peerName)")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        certification()
                    }
                    Spacer()
                    Color.clear.frame(width: 44)
                }
                .padding()
                .background(Color.black.opacity(0.82))
                ZStack {
                    localRenderer()
                    if input.isPreparing {
                        ProgressView("正在准备摄像头…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let reason = input.unavailableReason {
                    Text(reason)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                }
                if let error = input.startError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("video_call_preview_error")
                }
                HStack(spacing: 26) {
                    VideoRoundButton(
                        title: controlPresentation.cameraTitle,
                        systemImage: controlPresentation.cameraSystemImage
                    ) {
                        onToggleCamera()
                    }
                    .disabled(!controlPresentation.cameraControlEnabled)
                    .accessibilityIdentifier("video_call_preview_camera")
                    VideoRoundButton(
                        title: controlPresentation.startTitle,
                        systemImage: input.isStartingCall ? "hourglass" : "phone.fill",
                        tint: .green
                    ) {
                        onStart()
                    }
                    .disabled(input.isPreparing || input.isStartingCall)
                    .accessibilityIdentifier("video_call_preview_start")
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.88))
            }
        }
        .accessibilityIdentifier("video_call_preview")
    }
}
