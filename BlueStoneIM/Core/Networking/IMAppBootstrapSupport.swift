import Foundation

private struct IMAppBootstrapLastGoodEntry: Codable {
    let bootstrap: RemoteAppBootstrap
    let servingHost: String
    let savedAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case bootstrap
        case servingHost
        case savedAt
    }

    init(bootstrap: RemoteAppBootstrap, servingHost: String, savedAt: TimeInterval) {
        self.bootstrap = bootstrap
        self.servingHost = servingHost
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootstrap = try container.decode(RemoteAppBootstrap.self, forKey: .bootstrap)
        servingHost = try container.decodeIfPresent(String.self, forKey: .servingHost)
            ?? bootstrap.bootstrapHost
        savedAt = try container.decode(TimeInterval.self, forKey: .savedAt)
    }
}

struct IMAppBootstrapLastGoodSnapshot: Equatable {
    let bootstrap: RemoteAppBootstrap
    let servingHost: String
    let savedAt: TimeInterval
}

enum IMAppBootstrapLastGoodStore {
    private static let storageKey = "im2.appBootstrap.lastGood.v3"
    private static let previousStorageKey = "im2.appBootstrap.lastGood.v2"
    private static let legacyStorageKey = "im2.appBootstrap.lastGood.v1"

    static func save(
        _ bootstrap: RemoteAppBootstrap,
        appID rawAppID: String,
        environment rawEnvironment: String = "",
        servingHost rawServingHost: String? = nil,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID.isEmpty ? bootstrap.appID : rawAppID)
        let servingHost = normalizedHost(rawServingHost ?? bootstrap.bootstrapHost)
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !servingHost.isEmpty else { return }
        var entries = storedEntries(defaults: defaults)
        entries[scopeKey(appID: appID, environment: rawEnvironment, servingHost: servingHost)] =
            IMAppBootstrapLastGoodEntry(
                bootstrap: bootstrap,
                servingHost: servingHost,
                savedAt: now.timeIntervalSince1970
            )
        persist(entries, defaults: defaults)
    }

    static func load(
        appID rawAppID: String,
        environment rawEnvironment: String = "",
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> RemoteAppBootstrap? {
        snapshots(
            appID: rawAppID,
            environment: rawEnvironment,
            defaults: defaults,
            now: now,
            allowExpired: false
        )
        .sorted(by: snapshotOrder)
        .first?
        .bootstrap
    }

    static func snapshots(
        appID rawAppID: String,
        environment rawEnvironment: String = "",
        servingHosts rawServingHosts: [String]? = nil,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        allowExpired: Bool = false
    ) -> [IMAppBootstrapLastGoodSnapshot] {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let environment = normalizedEnvironment(rawEnvironment)
        let allowedHosts = rawServingHosts.map { Set($0.map(normalizedHost).filter { !$0.isEmpty }) }
        var collectedSnapshots: [IMAppBootstrapLastGoodSnapshot] = []

        func collect(_ entries: [String: IMAppBootstrapLastGoodEntry], legacy: Bool) {
            for (key, entry) in entries {
                let scope = parsedScope(key, legacy: legacy)
                let entryAppID = IMAPIContext.normalizedIOSAppID(
                    scope.appID.isEmpty ? entry.bootstrap.appID : scope.appID
                )
                let entryEnvironment = normalizedEnvironment(
                    scope.environment ?? (entry.bootstrap.environment ?? "")
                )
                let host = normalizedHost(
                    scope.servingHost.isEmpty ? entry.servingHost : scope.servingHost
                )
                guard entryAppID == appID,
                      entryEnvironment == environment,
                      !host.isEmpty,
                      allowedHosts?.contains(host) != false,
                      entry.savedAt.isFinite,
                      entry.savedAt > 0 else { continue }
                let expiresAt = entry.savedAt + TimeInterval(max(30, entry.bootstrap.ttlSeconds))
                guard allowExpired || expiresAt > now.timeIntervalSince1970 else { continue }
                let snapshot = IMAppBootstrapLastGoodSnapshot(
                    bootstrap: entry.bootstrap,
                    servingHost: host,
                    savedAt: entry.savedAt
                )
                collectedSnapshots.append(snapshot)
            }
        }

        collect(storedEntries(defaults: defaults), legacy: false)
        collect(storedEntries(defaults: defaults, key: previousStorageKey), legacy: true)
        collect(storedEntries(defaults: defaults, key: legacyStorageKey), legacy: true)
        // Keep every v3/v2/v1 candidate until the AppId-wide revision/hash
        // consistency check runs. Deduplicating by Host here can hide a
        // same-revision, different-hash migration conflict.
        return collectedSnapshots.sorted(by: snapshotOrder)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: previousStorageKey)
        defaults.removeObject(forKey: legacyStorageKey)
    }

    static func clear(appID rawAppID: String, defaults: UserDefaults = .standard) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.isEmpty else { return }
        for key in [storageKey, previousStorageKey, legacyStorageKey] {
            var entries = storedEntries(defaults: defaults, key: key)
            entries = entries.filter {
                IMAPIContext.normalizedIOSAppID(parsedScope($0.key, legacy: key != storageKey).appID) != appID
                    && IMAPIContext.normalizedIOSAppID($0.value.bootstrap.appID) != appID
            }
            persist(entries, defaults: defaults, key: key)
        }
    }

    private static func storedEntries(
        defaults: UserDefaults,
        key: String = storageKey
    ) -> [String: IMAppBootstrapLastGoodEntry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: IMAppBootstrapLastGoodEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(
        _ entries: [String: IMAppBootstrapLastGoodEntry],
        defaults: UserDefaults,
        key: String = storageKey
    ) {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func scopeKey(appID: String, environment: String, servingHost: String) -> String {
        "\(normalizedEnvironment(environment))\u{0}\(appID)\u{0}\(normalizedHost(servingHost))"
    }

    private static func parsedScope(
        _ key: String,
        legacy: Bool
    ) -> (environment: String?, appID: String, servingHost: String) {
        let components = key.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        if !legacy, components.count >= 3 {
            return (components[0], components[1], components[2])
        }
        if components.count >= 2 {
            return (components[0], components[1], "")
        }
        // Only v1 has no environment component. An explicit empty component
        // in v2/v3 is a real scope and must not be confused with absence.
        return (nil, key, "")
    }

    private static func snapshotOrder(
        _ lhs: IMAppBootstrapLastGoodSnapshot,
        _ rhs: IMAppBootstrapLastGoodSnapshot
    ) -> Bool {
        if lhs.bootstrap.routeRevision != rhs.bootstrap.routeRevision {
            return lhs.bootstrap.routeRevision > rhs.bootstrap.routeRevision
        }
        return lhs.savedAt > rhs.savedAt
    }

    private static func normalizedHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalizedEnvironment(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("$(") ? "" : value
    }
}

struct IMAppBootstrapHostConfiguration: Equatable, Sendable {
	static let maximumBaseCount = 5
	static let maximumPackagedBaseCount = 4
	static let maximumEffectiveBaseCount = maximumBaseCount + maximumPackagedBaseCount
	let orderedBases: [URL]

	var primary: URL { orderedBases[0] }
	var backup: URL? { orderedBases.dropFirst().first }

	var primaryHost: String {
		Self.normalizedHost(primary.host)
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	var allowedHosts: Set<String> {
		Set(orderedBases.map { Self.normalizedHost($0.host) }.filter { !$0.isEmpty })
	}

	func containsBase(_ base: URL) -> Bool {
		orderedBases.contains { configured in
			Self.sameOrigin(configured, base)
		}
	}

	func containsBootstrapHost(_ rawHost: String) -> Bool {
		let host = Self.normalizedHost(rawHost)
		return !host.isEmpty && allowedHosts.contains(host)
	}

	func base(matchingBootstrapHost rawHost: String) -> URL? {
		let host = Self.normalizedHost(rawHost)
		guard !host.isEmpty else { return nil }
		return orderedBases.first { Self.normalizedHost($0.host) == host }
	}

	private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
		normalizedHost(lhs.host) == normalizedHost(rhs.host)
			&& lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
			&& effectivePort(lhs) == effectivePort(rhs)
	}

	private static func effectivePort(_ url: URL) -> Int {
		url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	init?(orderedBases: [URL], allowLocalOrInsecure: Bool = false) {
		self.init(
			orderedBases: orderedBases,
			maximumCount: Self.maximumBaseCount,
			allowLocalOrInsecure: allowLocalOrInsecure
		)
	}

	init?(packagedOrderedBases: [URL], allowLocalOrInsecure: Bool = false) {
		self.init(
			orderedBases: packagedOrderedBases,
			maximumCount: Self.maximumPackagedBaseCount,
			allowLocalOrInsecure: allowLocalOrInsecure
		)
	}

	init?(effectiveOrderedBases: [URL], allowLocalOrInsecure: Bool = false) {
		self.init(
			orderedBases: effectiveOrderedBases,
			maximumCount: Self.maximumEffectiveBaseCount,
			allowLocalOrInsecure: allowLocalOrInsecure
		)
	}

	private init?(orderedBases: [URL], maximumCount: Int, allowLocalOrInsecure: Bool) {
		guard (1...maximumCount).contains(orderedBases.count) else { return nil }
		let cleanBases = orderedBases.compactMap {
			Self.normalizedBase($0, allowLocalOrInsecure: allowLocalOrInsecure)
		}
		guard cleanBases.count == orderedBases.count else { return nil }
		let hosts = cleanBases.map { Self.normalizedHost($0.host) }
		guard hosts.allSatisfy({ !$0.isEmpty }), Set(hosts).count == hosts.count else { return nil }
		self.orderedBases = cleanBases
	}

	init?(primary: URL, backup: URL?, allowLocalOrInsecure: Bool = false) {
		self.init(
			orderedBases: [primary] + (backup.map { [$0] } ?? []),
			allowLocalOrInsecure: allowLocalOrInsecure
		)
	}

	private static func normalizedBase(_ url: URL, allowLocalOrInsecure: Bool) -> URL? {
		let scheme = url.scheme?.lowercased() ?? ""
		let host = normalizedHost(url.host)
		let isLoopback = host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.")
		guard (scheme == "https" || (allowLocalOrInsecure && scheme == "http" && isLoopback)),
		      (scheme == "https" ? (url.port == nil || url.port == 443) : url.port != nil),
		      url.user == nil, url.password == nil,
		      url.query == nil, url.fragment == nil,
		      url.path.isEmpty || url.path == "/",
		      !host.isEmpty,
		      (Self.isPublicDNSHost(host) || (allowLocalOrInsecure && isLoopback)) else { return nil }
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		components?.scheme = scheme
		components?.host = host
		if scheme == "https" { components?.port = nil }
		components?.path = ""
		return components?.url
	}

	private static func normalizedHost(_ raw: String?) -> String {
		(raw ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
	}

	private static func isPublicDNSHost(_ host: String) -> Bool {
		guard host.count <= 253,
		      !host.hasSuffix("."),
		      !host.contains(":"),
		      host != "localhost",
		      !host.hasSuffix(".localhost"),
		      !host.hasSuffix(".invalid"),
		      !["placeholder", "change-me", "changeme", "replace-with"].contains(where: host.contains)
		else { return false }
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)
		guard labels.count >= 2,
		      !(labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
		else { return false }
		return labels.allSatisfy { label in
			guard (1...63).contains(label.count),
			      label.first != "-", label.last != "-" else { return false }
			return label.allSatisfy { character in
				character.isASCII && (character.isLowercase || character.isNumber || character == "-")
			}
		}
	}
}

enum IMAppBootstrapHostPlan: Equatable, Sendable {
	case configured(IMAppBootstrapHostConfiguration)
	case unconfigured
	case blocked
}

enum IMAppBootstrapHostConfigurationLoader {
	static let basesInfoKey = "WXTAppBootstrapBaseURLs"
	static let primaryInfoKey = "WXTAppBootstrapBaseURL"
	static let backupInfoKey = "WXTAppBootstrapBackupBaseURL"
	static let explicitlyUnconfiguredAppID = "WXT_UNCONFIGURED_APP2"

	static func load(info: [String: Any], appID rawAppID: String) -> IMAppBootstrapHostPlan {
		let appID = rawAppID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let primaryRaw = text(info[primaryInfoKey]),
		      let backupRaw = text(info[backupInfoKey]) else { return .blocked }
		let explicitlyUnconfigured = appID.caseInsensitiveCompare(explicitlyUnconfiguredAppID) == .orderedSame
		if let rawBases = info[basesInfoKey] {
			guard let values = rawBases as? [Any] else { return .blocked }
			let texts = values.compactMap(text)
			guard texts.count == values.count else { return .blocked }
			if texts.allSatisfy(\.isEmpty) {
				return primaryRaw.isEmpty && backupRaw.isEmpty && explicitlyUnconfigured
					? .unconfigured
					: .blocked
			}
			guard !explicitlyUnconfigured,
			      texts.allSatisfy({ !$0.isEmpty }),
			      texts.count <= IMAppBootstrapHostConfiguration.maximumPackagedBaseCount else {
				return .blocked
			}
			let bases = texts.compactMap(strictURL)
			guard bases.count == texts.count,
			      let configuration = IMAppBootstrapHostConfiguration(packagedOrderedBases: bases) else {
				return .blocked
			}
			// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
			// The ordered array is the authoritative allowlist. Legacy primary/backup
			// values may point at any listed origin, so backend-selected defaults do
			// not have to match the first local candidate.
			if !primaryRaw.isEmpty {
				guard let primary = strictURL(primaryRaw),
				      configuration.containsBase(primary) else { return .blocked }
			}
			if !backupRaw.isEmpty {
				guard let backup = strictURL(backupRaw),
				      configuration.containsBase(backup) else { return .blocked }
			}
			// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
			return .configured(configuration)
		}

		if primaryRaw.isEmpty {
			return backupRaw.isEmpty && explicitlyUnconfigured ? .unconfigured : .blocked
		}
		guard !explicitlyUnconfigured, let primary = strictURL(primaryRaw) else {
			return .blocked
		}
		let backup: URL?
		if backupRaw.isEmpty {
			backup = nil
		} else if let value = strictURL(backupRaw) {
			backup = value
		} else {
			return .blocked
		}
		guard let configuration = IMAppBootstrapHostConfiguration(primary: primary, backup: backup) else {
			return .blocked
		}
		return .configured(configuration)
	}

	private static func text(_ raw: Any?) -> String? {
		guard let raw else { return "" }
		guard let value = raw as? String,
		      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
		      !value.contains("$(") else { return nil }
		return value
	}

	private static func strictURL(_ raw: String) -> URL? {
		guard !raw.isEmpty, let url = URL(string: raw), url.absoluteString == raw else { return nil }
		return url
	}
}
