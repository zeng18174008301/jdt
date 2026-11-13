// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

struct GroupHistoryBoundaryGenerationTracker: Equatable {
    private(set) var generations: [String: Int] = [:]

    mutating func begin(key: String) -> Int {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return 0 }
        let next = (generations[normalizedKey] ?? 0) + 1
        generations[normalizedKey] = next
        return next
    }

    func accepts(key: String, generation: Int?) -> Bool {
        guard let generation, generation > 0 else { return true }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return true }
        return generations[normalizedKey] == generation
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
