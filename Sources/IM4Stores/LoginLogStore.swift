// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
import Combine
import IM4Domain

// WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_BEGIN
@MainActor
public final class LoginLogStore: ObservableObject {
    public init() {}
    @Published public var logs: [LoginLog] = []
    @Published public var isLoading = false
    @Published public var loadFailed = false

    public func reset() {
        logs = []
        isLoading = false
        loadFailed = false
    }
}
// WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_END
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END
