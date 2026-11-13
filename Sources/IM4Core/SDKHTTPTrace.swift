import Foundation

// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
/// Captured SDK uptime, duration, actual execution-thread flag. Never identity or permission.
public typealias SDKHTTPTraceObserver = @Sendable (UInt64, UInt64, Bool) -> Void
// WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_BEGIN
/// A causal edge only; nil means the physical producer had no captured diagnostic source.
public typealias SDKHTTPTraceSourceLinkObserver = @Sendable (UInt64?) -> Void
public typealias SDKHTTPTraceContext = (sourceCorrelation: UInt64, delivery: SDKHTTPTraceObserver,
    decode: SDKHTTPTraceObserver, linkToPhysicalSource: SDKHTTPTraceSourceLinkObserver)
// WDT_IOS1_PHASE6_SHARED_HTTP_SOURCE_LINK_20261111_END
public enum SDKHTTPTrace {
    @TaskLocal public static var current: SDKHTTPTraceContext?
}
// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
