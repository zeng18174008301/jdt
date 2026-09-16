import Foundation

enum UserSummaryV2Error: Error, Equatable {
    case unknownField(String)
    case invalidSchema
    case invalidContractVersion
    case invalidRevision
    case invalidIdentity
    case invalidAvatar
    case invalidCertification
}

private struct UserSummaryV2AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectSensitiveUserSummaryFields(from decoder: Decoder, depth: Int = 0) throws {
    guard depth <= 32 else {
        throw UserSummaryV2Error.invalidIdentity
    }
    let sensitiveFields: Set<String> = [
        "analytics", "analytics_availability", "analytics_generation",
        "analytics_metrics", "admin_notes", "audit_actor", "behavior_analysis", "city",
        "internal_capabilities", "internal_role", "internal_view", "ip",
        "key_account", "key_account_generation", "last_login",
        "last_login_city", "last_login_ip", "login_history",
        "merchant_admin_note", "note", "operator_private_note", "phone",
        "phone_binding", "phone_masked", "phone_possession", "phone_verified",
        "private_note", "private_remark", "real_name", "real_name_status", "real_name_verified",
        "role_binding", "verification"
    ]
    if let container = try? decoder.container(keyedBy: UserSummaryV2AnyCodingKey.self) {
        for key in container.allKeys {
            let normalized = normalizedUserSummaryField(key.stringValue)
            if sensitiveFields.contains(normalized)
                || ["analytics_", "key_account_", "last_login_", "phone_", "real_name_"]
                    .contains(where: { normalized.hasPrefix($0) }) {
                throw UserSummaryV2Error.unknownField(key.stringValue)
            }
            try rejectSensitiveUserSummaryFields(
                from: container.superDecoder(forKey: key),
                depth: depth + 1
            )
        }
        return
    }
    if var container = try? decoder.unkeyedContainer() {
        while !container.isAtEnd {
            try rejectSensitiveUserSummaryFields(
                from: container.superDecoder(),
                depth: depth + 1
            )
        }
    }
}

private func normalizedUserSummaryField(_ value: String) -> String {
    var normalized = ""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 65...90:
            if !normalized.isEmpty {
                normalized.append("_")
            }
            normalized.append(Character(String(scalar).lowercased()))
        case 45, 32:
            normalized.append("_")
        default:
            normalized.append(Character(scalar))
        }
    }
    return normalized.lowercased()
}

struct UserSummaryV2: Codable, Equatable, Sendable {
    struct Generations: Codable, Equatable, Sendable {
        let identity: Int64
        let certification: Int64?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case identity
            case certification
        }

        init(identity: Int64, certification: Int64? = nil) {
            self.identity = identity
            self.certification = certification
        }

        init(from decoder: Decoder) throws {
            try rejectSensitiveUserSummaryFields(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decode(Int64.self, forKey: .identity)
            certification = try container.decodeIfPresent(Int64.self, forKey: .certification)
            guard identity >= 0, certification.map({ $0 >= 0 }) ?? true else {
                throw UserSummaryV2Error.invalidRevision
            }
        }
    }

    struct Avatar: Codable, Equatable, Sendable {
        let url: String
        let version: String
        let source: String
        let catalogVersion: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case url
            case version
            case source
            case catalogVersion = "catalog_version"
        }

        init(url: String, version: String, source: String, catalogVersion: String? = nil) {
            self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
            self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
            self.catalogVersion = catalogVersion
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        init(from decoder: Decoder) throws {
            try rejectSensitiveUserSummaryFields(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                url: try container.decode(String.self, forKey: .url),
                version: try container.decode(String.self, forKey: .version),
                source: try container.decode(String.self, forKey: .source),
                catalogVersion: try container.decodeIfPresent(String.self, forKey: .catalogVersion)
            )
        }
    }

    struct Certification: Codable, Equatable, Sendable {
        let verified: Bool
        let label: String
        let style: String
        let revision: Int64

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case verified
            case label
            case style
            case revision
        }

        init(verified: Bool, label: String, style: String, revision: Int64) {
            self.verified = verified
            self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            self.style = style.trimmingCharacters(in: .whitespacesAndNewlines)
            self.revision = revision
        }

        init(from decoder: Decoder) throws {
            try rejectSensitiveUserSummaryFields(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                verified: try container.decode(Bool.self, forKey: .verified),
                label: try container.decode(String.self, forKey: .label),
                style: try container.decode(String.self, forKey: .style),
                revision: try container.decode(Int64.self, forKey: .revision)
            )
            guard verified, !label.isEmpty, !style.isEmpty, revision >= 0 else {
                throw UserSummaryV2Error.invalidCertification
            }
        }
    }

    static let schemaName = "user_summary.v2"
    static let currentContractVersion = 1

    let schema: String
    let contractVersion: Int
    let userRevision: Int64
    let generations: Generations
    let imUID: String
    let userID: String
    let displayName: String
    let displayNameSource: String
    let rawNickname: String
    let avatar: Avatar
    let certification: Certification?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case contractVersion = "contract_version"
        case userRevision = "user_revision"
        case generations
        case imUID = "im_uid"
        case userID = "user_id"
        case displayName = "display_name"
        case displayNameSource = "display_name_source"
        case rawNickname = "raw_nickname"
        case avatar
        case certification
    }

    init(
        schema: String = UserSummaryV2.schemaName,
        contractVersion: Int = UserSummaryV2.currentContractVersion,
        userRevision: Int64,
        generations: Generations,
        imUID: String,
        userID: String,
        displayName: String,
        displayNameSource: String,
        rawNickname: String,
        avatar: Avatar,
        certification: Certification?
    ) throws {
        self.schema = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contractVersion = contractVersion
        self.userRevision = userRevision
        self.generations = generations
        self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayNameSource = displayNameSource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawNickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatar = avatar
        self.certification = certification
        try validate()
    }

    init(from decoder: Decoder) throws {
        try rejectSensitiveUserSummaryFields(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: try container.decode(String.self, forKey: .schema),
            contractVersion: try container.decode(Int.self, forKey: .contractVersion),
            userRevision: try container.decode(Int64.self, forKey: .userRevision),
            generations: try container.decode(Generations.self, forKey: .generations),
            imUID: try container.decode(String.self, forKey: .imUID),
            userID: try container.decode(String.self, forKey: .userID),
            displayName: try container.decode(String.self, forKey: .displayName),
            displayNameSource: try container.decode(String.self, forKey: .displayNameSource),
            rawNickname: try container.decode(String.self, forKey: .rawNickname),
            avatar: try container.decode(Avatar.self, forKey: .avatar),
            certification: try container.decodeIfPresent(Certification.self, forKey: .certification)
        )
    }

    private func validate() throws {
        guard schema == Self.schemaName else {
            throw UserSummaryV2Error.invalidSchema
        }
        guard contractVersion == Self.currentContractVersion else {
            throw UserSummaryV2Error.invalidContractVersion
        }
        guard userRevision >= 0,
              generations.identity >= 0,
              generations.certification.map({ $0 >= 0 }) ?? true else {
            throw UserSummaryV2Error.invalidRevision
        }
        guard !imUID.isEmpty,
              !userID.isEmpty,
              !displayName.isEmpty,
              !displayNameSource.isEmpty else {
            throw UserSummaryV2Error.invalidIdentity
        }
        guard !avatar.url.isEmpty, !avatar.version.isEmpty, !avatar.source.isEmpty else {
            throw UserSummaryV2Error.invalidAvatar
        }
        if let catalogVersion = avatar.catalogVersion, catalogVersion.isEmpty {
            throw UserSummaryV2Error.invalidAvatar
        }
        if avatar.source == "system_default", avatar.catalogVersion != "v2" {
            throw UserSummaryV2Error.invalidAvatar
        }
        if let certification {
            guard certification.verified,
                  !certification.label.isEmpty,
                  !certification.style.isEmpty,
                  certification.revision >= 0 else {
                throw UserSummaryV2Error.invalidCertification
            }
        }
    }
}

enum IdentityPresentationSlot: String, CaseIterable, Sendable {
    case avatarLowerLeft = "online"
    case avatarLowerRight = "certification"
    case afterNameCertificationPill = "certification_pill"
    case afterNameGroupRole = "group_role"
    case metadataStatus = "status"
    case trailing
}

struct IdentityPresentationDecoration: Equatable, Sendable {
    let slot: IdentityPresentationSlot
    let value: String
    let accessibilityLabel: String

    init(
        slot: IdentityPresentationSlot,
        value: String,
        accessibilityLabel: String
    ) {
        self.slot = slot
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessibilityLabel = accessibilityLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct IdentityPresentationContext: Equatable, Sendable {
    let online: Bool?
    let groupRole: String?
    let status: String?
    let trailing: String?
    let explicitDecorations: [IdentityPresentationDecoration]

    init(
        online: Bool? = nil,
        groupRole: String? = nil,
        status: String? = nil,
        trailing: String? = nil,
        explicitDecorations: [IdentityPresentationDecoration] = []
    ) {
        self.online = online
        self.groupRole = groupRole
        self.status = status
        self.trailing = trailing
        self.explicitDecorations = explicitDecorations
    }
}

struct IdentityPresentation: Equatable, Sendable {
    let displayName: String
    let avatarURL: String
    let avatarVersion: String
    let onlineDecoration: IdentityPresentationDecoration?
    let certificationDecoration: IdentityPresentationDecoration?
    let certificationPill: IdentityPresentationDecoration?
    let groupRoleDecoration: IdentityPresentationDecoration?
    let statusDecoration: IdentityPresentationDecoration?
    let trailingDecoration: IdentityPresentationDecoration?
    let afterNameDecorations: [IdentityPresentationDecoration]
    let accessibilityName: String

    init(summary: UserSummaryV2, context: IdentityPresentationContext = .init()) {
        displayName = summary.displayName
        avatarURL = summary.avatar.url
        avatarVersion = summary.avatar.version

        onlineDecoration = nil
        certificationDecoration = context.explicitDecorations
            .first(where: { $0.slot == .avatarLowerRight })
            .flatMap(Self.validDecoration)
        certificationPill = context.explicitDecorations
            .first(where: { $0.slot == .afterNameCertificationPill })
            .flatMap(Self.validDecoration)
        groupRoleDecoration = context.groupRole
            .flatMap(Self.nonEmpty)
            .map {
                IdentityPresentationDecoration(
                    slot: .afterNameGroupRole,
                    value: $0,
                    accessibilityLabel: "群角色：\($0)"
                )
            }
        statusDecoration = context.status
            .flatMap(Self.nonEmpty)
            .map {
                IdentityPresentationDecoration(
                    slot: .metadataStatus,
                    value: $0,
                    accessibilityLabel: "状态：\($0)"
                )
            }
        trailingDecoration = context.trailing
            .flatMap(Self.nonEmpty)
            .map {
                IdentityPresentationDecoration(
                    slot: .trailing,
                    value: $0,
                    accessibilityLabel: $0
                )
            }

        afterNameDecorations = [
            certificationPill,
            groupRoleDecoration
        ].compactMap { $0 }
        let labels = [
            displayName,
            certificationPill?.accessibilityLabel ?? certificationDecoration?.accessibilityLabel,
            groupRoleDecoration?.accessibilityLabel,
            statusDecoration?.accessibilityLabel,
            trailingDecoration?.accessibilityLabel
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        accessibilityName = labels.joined(separator: "，")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func validDecoration(
        _ decoration: IdentityPresentationDecoration
    ) -> IdentityPresentationDecoration? {
        decoration.value.isEmpty || decoration.accessibilityLabel.isEmpty
            ? nil
            : decoration
    }
}
