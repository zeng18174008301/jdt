import Foundation
import IM4Core

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN
typealias HTTPTransportResult = IM4Core.HTTPTransportResult
typealias HTTPTransport = IM4Core.HTTPTransport
typealias HTTPTransporting = IM4Core.HTTPTransporting
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END

// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
import IM4Data

typealias HTTPInFlightTaskClaim<Value: Sendable> = IM4Data.HTTPInFlightTaskClaim<Value>
typealias HTTPInFlightRequestStore<Value: Sendable> = IM4Data.HTTPInFlightRequestStore<Value>
typealias URLSessionHTTPTransport = IM4Data.URLSessionHTTPTransport
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END
