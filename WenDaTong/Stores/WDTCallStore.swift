import Combine
import Foundation
import IM4Data // WDT_IOS1_DATA17_M17_REAL_IO_CONSUMERS_20261111
import IM4Domain
import IM4Stores // WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111

typealias CallRecordPersisting = IM4Stores.CallRecordPersisting

final class UserDefaultsCallRecordStore: CallRecordPersisting {
    private static let defaultStorageKey = "im2.ios.callRecords"
    private let archiveStorage: IM4Data.CallRecordArchiveStorage
    private let maxStoredRecords: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = UserDefaultsCallRecordStore.defaultStorageKey,
        archiveURL: URL? = nil,
        maxStoredRecords: Int = 20
    ) {
        self.archiveStorage = IM4Data.CallRecordArchiveStorage(
            defaults: defaults, storageKey: storageKey,
            archiveURL: archiveURL ?? (storageKey == Self.defaultStorageKey ? Self.defaultArchiveURL() : nil),
            onDiskWriteFailure: Self.diskWriteFailed
        )
        self.maxStoredRecords = max(1, maxStoredRecords)
    }

    func load(scope: String) -> [CallRecord] {
        let normalizedScope = normalized(scope)
        guard !normalizedScope.isEmpty else { return [] }
        let records = Array(archiveStorage.records(scope: normalizedScope).prefix(maxStoredRecords))
        debugLog("load", scope: normalizedScope, count: records.count)
        return records
    }

    func save(_ records: [CallRecord], scope: String) {
        let normalizedScope = normalized(scope)
        guard !normalizedScope.isEmpty else { return }
        let limitedRecords = Array(records.prefix(maxStoredRecords))
        archiveStorage.save(limitedRecords, scope: normalizedScope)
        debugLog("save", scope: normalizedScope, count: limitedRecords.count)
    }

    private func normalized(_ scope: String) -> String {
        scope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func diskWriteFailed(_ error: any Error) {
        #if DEBUG
        print("[JHT CallRecord] disk_write_failed \(error.localizedDescription)")
        #endif
    }

    private static func defaultArchiveURL() -> URL? {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let base else { return nil }
        return base
            .appendingPathComponent("BlueStoneIM", isDirectory: true)
            .appendingPathComponent("CallRecords", isDirectory: true)
            .appendingPathComponent("call-records.json", isDirectory: false)
    }

    private func debugLog(_ action: String, scope: String, count: Int) {
        #if DEBUG
        print("[JHT CallRecord] \(action) scope=\(Self.scopeLogToken(scope)) count=\(count)")
        #endif
    }

    private static func scopeLogToken(_ scope: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

typealias CallStore = IM4Stores.CallStore

// App retains scope/key policy and the single default construction; typed archive IO is IM4Data.
extension IM4Stores.CallStore {
    convenience init() {
        self.init(callRecordStore: UserDefaultsCallRecordStore())
    }
}
