import CryptoKit
import Foundation
import UIKit

enum IOSSceneCaptureTraitState: Equatable, Sendable {
    case active
    case inactive
    case unspecified
}

@MainActor
protocol IOSSceneCaptureSource: AnyObject {
    var sceneIdentifier: String { get }
    var sceneTraitCaptureState: IOSSceneCaptureTraitState { get }
    var boundScreenIsCaptured: Bool { get }
}

@MainActor
enum IOSSceneCaptureResolver {
    static func isCaptured(boundSource: any IOSSceneCaptureSource, supportsSceneCaptureTrait: Bool) -> Bool {
        if supportsSceneCaptureTrait {
            return boundSource.sceneTraitCaptureState == .active
        }
        return boundSource.boundScreenIsCaptured
    }
}

@MainActor
private final class IOSWindowSceneCaptureSource: IOSSceneCaptureSource {
    private weak var windowScene: UIWindowScene?

    init(windowScene: UIWindowScene) {
        self.windowScene = windowScene
    }

    var sceneIdentifier: String {
        windowScene?.session.persistentIdentifier ?? ""
    }

    var sceneTraitCaptureState: IOSSceneCaptureTraitState {
        guard #available(iOS 17.0, *), let windowScene else { return .unspecified }
        switch windowScene.traitCollection.sceneCaptureState {
        case .active: return .active
        case .inactive: return .inactive
        default: return .unspecified
        }
    }

    var boundScreenIsCaptured: Bool {
        windowScene?.screen.isCaptured == true
    }
}

@MainActor
final class IOSSceneCaptureMonitor: NSObject {
    typealias ChangeHandler = @MainActor (Bool) -> Void

    var onChange: ChangeHandler?

    private weak var windowScene: UIWindowScene?
    private var source: IOSWindowSceneCaptureSource?
    private var traitRegistration: AnyObject?
    private var isObservingLegacyScreen = false

    var currentIsCaptured: Bool {
        guard let source else { return false }
        return IOSSceneCaptureResolver.isCaptured(
            boundSource: source,
            supportsSceneCaptureTrait: Self.supportsSceneCaptureTrait
        )
    }

    func bind(windowScene: UIWindowScene?) {
        guard self.windowScene !== windowScene else {
            publishCurrentValue()
            return
        }
        stopObserving()
        self.windowScene = windowScene
        source = windowScene.map(IOSWindowSceneCaptureSource.init)
        guard let windowScene else {
            publishCurrentValue()
            return
        }
        if #available(iOS 17.0, *) {
            traitRegistration = windowScene.registerForTraitChanges(
                [UITraitSceneCaptureState.self],
                target: self,
                action: #selector(sceneCaptureTraitDidChange)
            ) as AnyObject
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundScreenCaptureDidChange(_:)),
                name: UIScreen.capturedDidChangeNotification,
                object: nil
            )
            isObservingLegacyScreen = true
        }
        publishCurrentValue()
    }

    private static var supportsSceneCaptureTrait: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    private func stopObserving() {
        if #available(iOS 17.0, *),
           let windowScene,
           let traitRegistration = traitRegistration as? any UITraitChangeRegistration {
            windowScene.unregisterForTraitChanges(traitRegistration)
        }
        traitRegistration = nil
        if isObservingLegacyScreen {
            NotificationCenter.default.removeObserver(self, name: UIScreen.capturedDidChangeNotification, object: nil)
            isObservingLegacyScreen = false
        }
        source = nil
    }

    private func publishCurrentValue() {
        onChange?(currentIsCaptured)
    }

    @objc private func sceneCaptureTraitDidChange() {
        publishCurrentValue()
    }

    @objc private func boundScreenCaptureDidChange(_ notification: Notification) {
        guard let windowScene else { return }
        if let changedScreen = notification.object as? UIScreen,
           changedScreen !== windowScene.screen {
            return
        }
        publishCurrentValue()
    }
}
