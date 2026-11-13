// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

protocol MessageStore: Sendable {
    var schemaVersion: Int { get }

    /// Builds a stable, normalized cache scope from the account/tenant/user/app/device identity tuple.
    func scopeKey(for context: IMAPIContext) -> String
    /// Loads a cached snapshot only when the stored schema, scope, age, and content are valid.
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult?
    /// Schedules a write and rejects snapshots whose embedded scope does not match the target scope.
    @discardableResult
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool
    /// Writes immediately and rejects snapshots whose embedded scope does not match the target scope.
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool
    /// Removes only the requested scope.
    func remove(scope: String)
    /// Removes every snapshot owned by this store implementation.
    func removeAll()
}

extension SnapshotCache: MessageStore {
    func scopeKey(for context: IMAPIContext) -> String {
        [
            "v2",
            "account=\(Self.scopeComponent(context.accountID))",
            "tenant=\(Self.scopeComponent(context.tenantID))",
            "im=\(Self.scopeComponent(context.imUID))",
            "app=\(Self.scopeComponent(context.appID))",
            "device=\(Self.scopeComponent(context.deviceID))"
        ].joined(separator: "|")
    }

    private static func scopeComponent(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return Data(trimmed.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
