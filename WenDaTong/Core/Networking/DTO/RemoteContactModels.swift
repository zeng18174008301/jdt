import Foundation
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteFriendRelation = IM4Data.RemoteFriendRelation
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteFriendProfile = IM4Data.RemoteFriendProfile
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteBlacklistRelation = IM4Data.RemoteBlacklistRelation
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteFriendApplication = IM4Data.RemoteFriendApplication
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteUserSearchItem = IM4Data.RemoteUserSearchItem
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

enum RemoteUserSummaryProjection: Equatable, Sendable {
    case authoritative(UserSummaryV2)
    case authoritativeOmission
    case malformed
}

enum RemoteUserProfilesError: Error, Equatable {
    case invalidUID
    case duplicateUID(String)
    case overlappingUID(String)
    case invalidLimit
    case tooManyResults
}

struct RemoteUserProfileSummary: Decodable, Equatable, Sendable {
    let imUID: String
    let userID: String
    let userSummaryProjection: RemoteUserSummaryProjection

    private enum CodingKeys: String, CodingKey {
        case imUID = "im_uid"
        case userID = "user_id"
        case userSummary = "user_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imUID = try container.decode(String.self, forKey: .imUID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? imUID
        guard !imUID.isEmpty else {
            throw RemoteUserProfilesError.invalidUID
        }
        guard let rawSummary = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .userSummary
        ) else {
            userSummaryProjection = .authoritativeOmission
            return
        }
        guard case .object = rawSummary,
              let data = try? JSONEncoder().encode(rawSummary),
              let summary = try? JSONDecoder().decode(UserSummaryV2.self, from: data),
              userID == imUID,
              summary.imUID == imUID,
              summary.userID == imUID else {
            userSummaryProjection = .malformed
            return
        }
        userSummaryProjection = .authoritative(summary)
    }
}

struct RemoteUserProfilesResponse: Decodable, Equatable, Sendable {
    let items: [RemoteUserProfileSummary]
    let missingUIDs: [String]
    let maxUIDs: Int

    private enum CodingKeys: String, CodingKey {
        case items
        case missingUIDs = "missing_uids"
        case maxUIDs = "max_uids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([RemoteUserProfileSummary].self, forKey: .items)
        missingUIDs = try container.decode([String].self, forKey: .missingUIDs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        maxUIDs = try container.decode(Int.self, forKey: .maxUIDs)
        guard maxUIDs > 0, maxUIDs <= CertificationProfileUIDBatch.maximumCount else {
            throw RemoteUserProfilesError.invalidLimit
        }
        guard items.count + missingUIDs.count <= maxUIDs else {
            throw RemoteUserProfilesError.tooManyResults
        }

        var itemUIDs: Set<String> = []
        for item in items {
            guard itemUIDs.insert(item.imUID).inserted else {
                throw RemoteUserProfilesError.duplicateUID(item.imUID)
            }
        }
        var missingSet: Set<String> = []
        for uid in missingUIDs {
            guard !uid.isEmpty else {
                throw RemoteUserProfilesError.invalidUID
            }
            guard missingSet.insert(uid).inserted else {
                throw RemoteUserProfilesError.duplicateUID(uid)
            }
            guard !itemUIDs.contains(uid) else {
                throw RemoteUserProfilesError.overlappingUID(uid)
            }
        }
    }
}

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteFriendApplyResult = IM4Data.RemoteFriendApplyResult
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END
