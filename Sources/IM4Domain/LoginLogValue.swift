// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
public struct LoginLog: Identifiable, Hashable, Sendable {
    public let id: String
    public let device: String
    public let location: String
    public let time: String
    public let result: String

    public init(id: String, device: String, location: String, time: String, result: String) {
        self.id = id
        self.device = device
        self.location = location
        self.time = time
        self.result = result
    }
}
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END
