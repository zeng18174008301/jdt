import Combine
import Foundation

enum PreloginBootstrapInfoKey {
    static let enabled = "WXTPreloginBootstrapEnabled"
    static let sources = "WXTPreloginBootstrapSources"
    static let sourcesJSON = "WXTPreloginBootstrapSourcesJSON"
    static let environment = "WXTPreloginBootstrapEnvironment"
    static let productID = "WXTPreloginBootstrapProductID"
    static let appID = "WXTPreloginBootstrapAppID"
    static let channel = "WXTPreloginBootstrapChannel"
    static let recoveryRootKeyID = "WXTPreloginBootstrapRecoveryRootKeyID"
    static let recoveryRootPublicKey = "WXTPreloginBootstrapRecoveryRootPublicKeyBase64"
    static let artifactPublicKeys = "WXTPreloginBootstrapArtifactPublicKeys"
    static let artifactPublicKeysJSON = "WXTPreloginBootstrapArtifactPublicKeysJSON"
}

enum PreloginBootstrapStartupPlan: Sendable {
    case disabled
    case enabled(PreloginBootstrapConfiguration)
    case blocked
}

enum PreloginBootstrapStartupConfiguration {
    private static let requiredSourceIDs: Set<String> = [
        "primary",
        "cross-account",
        "cross-provider"
    ]

    static func load(info: [String: Any], bundleID: String?) -> PreloginBootstrapStartupPlan {
        guard let enabled = parseBoolean(info[PreloginBootstrapInfoKey.enabled]) else {
            return .blocked
        }
        guard enabled else {
            return .disabled
        }
        guard let bundleID = boundedString(bundleID, maximum: 255),
              let environment = boundedString(
                info[PreloginBootstrapInfoKey.environment],
                maximum: 32
              ),
              let productID = boundedString(
                info[PreloginBootstrapInfoKey.productID],
                maximum: 128
              ),
              let appID = boundedString(
                info[PreloginBootstrapInfoKey.appID],
                maximum: 128
              ),
              appID == IMAPIContext.normalizedIOSAppID(
                appID,
                allowCustomAppID: false
              ),
              let channel = boundedString(
                info[PreloginBootstrapInfoKey.channel],
                maximum: 64
              ),
              let rootKeyID = boundedString(
                info[PreloginBootstrapInfoKey.recoveryRootKeyID],
                maximum: 128
              ),
              let rootPublicKey = decodePublicKey(
                info[PreloginBootstrapInfoKey.recoveryRootPublicKey]
              ),
              let artifactPublicKeys = decodeArtifactPublicKeys(
                info[PreloginBootstrapInfoKey.artifactPublicKeys]
              ) ?? decodeArtifactPublicKeysJSON(
                info[PreloginBootstrapInfoKey.artifactPublicKeysJSON]
              ),
              let seeds = decodeSeeds(info[PreloginBootstrapInfoKey.sources])
                ?? decodeSeedsJSON(info[PreloginBootstrapInfoKey.sourcesJSON]) else {
            return .blocked
        }

        let configuration = PreloginBootstrapConfiguration(
            seeds: seeds,
            scope: PreloginExpectedScope(
                environment: environment,
                productID: productID,
                appID: appID,
                bundleID: bundleID,
                channel: channel,
                platform: "ios"
            ),
            rootKeyID: rootKeyID,
            rootPublicKey: rootPublicKey,
            artifactPublicKeys: artifactPublicKeys
        )
        do {
            try configuration.validate()
            return .enabled(configuration)
        } catch {
            return .blocked
        }
    }

    static func load(bundle: Bundle = .main) -> PreloginBootstrapStartupPlan {
        load(
            info: bundle.infoDictionary ?? [:],
            bundleID: bundle.bundleIdentifier
        )
    }

    private static func parseBoolean(_ raw: Any?) -> Bool? {
        guard let raw else { return false }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber {
            if number == 0 { return false }
            if number == 1 { return true }
            return nil
        }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "0", "false", "no": return false
            case "1", "true", "yes": return true
            default: return nil
            }
        }
        return nil
    }

    private static func boundedString(_ raw: Any?, maximum: Int) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value == raw,
              value.utf8.count <= maximum,
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\t")) == nil else {
            return nil
        }
        return value
    }

    private static func decodePublicKey(_ raw: Any?) -> Data? {
        guard let value = boundedString(raw, maximum: 128),
              let decoded = Data(base64Encoded: value, options: []),
              decoded.count == 32 else {
            return nil
        }
        return decoded
    }

    private static func decodeArtifactPublicKeys(_ raw: Any?) -> [String: Data]? {
        guard let raw = raw as? [String: Any],
              !raw.isEmpty,
              raw.count <= 16 else {
            return nil
        }
        var decoded: [String: Data] = [:]
        for (rawKeyID, rawPublicKey) in raw {
            guard let keyID = boundedString(rawKeyID, maximum: 128),
                  let publicKey = decodePublicKey(rawPublicKey) else {
                return nil
            }
            decoded[keyID] = publicKey
        }
        return decoded.count == raw.count ? decoded : nil
    }

    private static func decodeArtifactPublicKeysJSON(_ raw: Any?) -> [String: Data]? {
        guard let object = decodeJSON(raw) as? [String: Any] else { return nil }
        return decodeArtifactPublicKeys(object)
    }

    private static func decodeSeeds(_ raw: Any?) -> [PreloginSeed]? {
        guard let raw = raw as? [[String: Any]], raw.count == 3 else {
            return nil
        }
        var seeds: [PreloginSeed] = []
        for item in raw {
            guard Set(item.keys) == ["id", "url"],
                  let id = boundedString(item["id"], maximum: 128),
                  let rawURL = boundedString(item["url"], maximum: 2_048),
                  let url = URL(string: rawURL) else {
                return nil
            }
            seeds.append(PreloginSeed(id: id, baseURL: url))
        }
        return Set(seeds.map(\.id)) == requiredSourceIDs ? seeds : nil
    }

    private static func decodeSeedsJSON(_ raw: Any?) -> [PreloginSeed]? {
        guard let object = decodeJSON(raw) as? [[String: Any]] else { return nil }
        return decodeSeeds(object)
    }

    private static func decodeJSON(_ raw: Any?) -> Any? {
        guard let value = raw as? String,
              !value.isEmpty,
              value.utf8.count <= 16_384,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

protocol PreloginPlatformBaseResolving: Sendable {
    func resolvePlatformBase() async throws -> URL
}

extension PreloginBootstrapResolver: PreloginPlatformBaseResolving {}

@MainActor
final class PreloginBootstrapStartupGate: ObservableObject {
    enum State: Equatable {
        case resolving
        case ready(URL?)
        case blocked
    }

    @Published private(set) var state: State

    private let resolver: (any PreloginPlatformBaseResolving)?
    private var resolutionTask: Task<URL, Error>?

    init(
        plan: PreloginBootstrapStartupPlan,
        resolverFactory: (PreloginBootstrapConfiguration) -> any PreloginPlatformBaseResolving = {
            PreloginBootstrapResolver(configuration: $0)
        }
    ) {
        switch plan {
        case .disabled:
            state = .ready(nil)
            resolver = nil
        case let .enabled(configuration):
            state = .resolving
            resolver = resolverFactory(configuration)
        case .blocked:
            state = .blocked
            resolver = nil
        }
    }

    func start() async {
        guard let resolver else { return }
        if case .ready = state { return }

        let task: Task<URL, Error>
        if let resolutionTask {
            task = resolutionTask
        } else {
            state = .resolving
            let newTask = Task { try await resolver.resolvePlatformBase() }
            resolutionTask = newTask
            task = newTask
        }

        do {
            let platformBase = try await task.value
            guard resolutionTask != nil else { return }
            resolutionTask = nil
            state = .ready(platformBase)
        } catch {
            guard resolutionTask != nil else { return }
            resolutionTask = nil
            state = .blocked
        }
    }

    func retry() {
        guard resolver != nil, resolutionTask == nil else { return }
        state = .resolving
        Task { await start() }
    }
}
