// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public enum BatchForwardSenderProvenance: String, Codable, Sendable {
    case authoritativeStored = "authoritative_stored"
    case clientSupplied = "client_supplied"
    case cachedUnverified = "cached_unverified"
    case unknown
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
