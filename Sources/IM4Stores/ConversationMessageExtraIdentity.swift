import Foundation
import IM4Domain
import IM4Data

public extension RemoteMessageExtra {
    var normalizedExtraType: String {
        (extraType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isReaction: Bool {
        normalizedExtraType == "reaction" || !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var operatorName: String {
        payload["nickname"]?.stringValue
            ?? payload["display_name"]?.stringValue
            ?? payload["operator_name"]?.stringValue
            ?? payload["actor_name"]?.stringValue
            ?? payload["name"]?.stringValue
            ?? ""
    }

    var dedupeKey: String {
		[messageID, String(version), operatorUID, emoji, action, createdAt ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    var editRevision: Int64 {
        if let value = payload["edit_revision"]?.stringValue,
           let revision = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           revision > 0 {
            return revision
        }
        if let nested = payload["payload"]?.objectValue {
            let value = nested["edit_revision"]?.stringValue ?? nested["editRevision"]?.stringValue ?? ""
            if let revision = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), revision > 0 {
                return revision
            }
        }
        return 0
    }
}
