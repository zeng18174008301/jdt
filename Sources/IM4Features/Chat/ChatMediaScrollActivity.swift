import SwiftUI

@MainActor
final public class ChatMediaScrollActivity {
    private var lastMotion = -Double.infinity
    private var nativeScrollInMotion = false
    private let idleInterval: TimeInterval = 0.18

    public func recordMotion() {
        lastMotion = ProcessInfo.processInfo.systemUptime
    }

    public func recordOffsetChange() {
        let now = ProcessInfo.processInfo.systemUptime
        // Extend an active drag through deceleration. A layout or anchor jump
        // long after the gesture does not hold up media loading.
        if now - lastMotion < idleInterval {
            lastMotion = now
        }
    }

    func recordScrollPhase(isScrolling: Bool) {
        if isScrolling || nativeScrollInMotion { recordMotion() }
        nativeScrollInMotion = isScrolling
    }

    public func resetMotion() {
        nativeScrollInMotion = false
        lastMotion = -Double.infinity
    }

    // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_BEGIN
    public var isIdle: Bool {
        !nativeScrollInMotion && ProcessInfo.processInfo.systemUptime - lastMotion >= idleInterval
    }

    public func waitForHistoryCommit() async -> Bool {
        if isIdle { return !Task.isCancelled }
        return await waitUntilIdle()
    }
    // WDT_IOS1_CHAT_THUMBNAIL_INERTIA_20261113_END

    public func waitUntilIdle() async -> Bool {
        var remaining = idleInterval
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return false
            }
            remaining = idleInterval - (ProcessInfo.processInfo.systemUptime - lastMotion)
            if remaining <= 0, !nativeScrollInMotion { return true }
            // Native deceleration can outlast geometry notifications, for
            // example when the offset moves by less than a point per frame.
            if nativeScrollInMotion { remaining = idleInterval }
        }
        return false
    }

    public init() {}
}

private enum ChatMediaScrollActivityKey: EnvironmentKey {
    static let defaultValue: ChatMediaScrollActivity? = nil
}

extension EnvironmentValues {
    public var chatMediaScrollActivity: ChatMediaScrollActivity? {
        get { self[ChatMediaScrollActivityKey.self] }
        set { self[ChatMediaScrollActivityKey.self] = newValue }
    }
}
