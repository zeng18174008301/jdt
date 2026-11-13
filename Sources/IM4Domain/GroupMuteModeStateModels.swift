// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
import Foundation

public enum GroupMuteLifecycle: String, Equatable, Sendable {
    case off
    case alwaysActive = "always_active"
    case scheduledPending = "scheduled_pending"
    case scheduledActive = "scheduled_active"
    case scheduledEnded = "scheduled_ended"
    case repairRequired = "repair_required"
}

public enum GroupMuteModeValidationError: String, Error, Equatable, Sendable {
    case badRequest = "bad_request"
    case invalidMode = "invalid_group_mute_mode"
    case invalidWindow = "invalid_group_mute_window"
}

public struct GroupMuteModeIntent: Equatable, Sendable {
    public let allMuted: Bool
    public let modeRawValue: String?
    public let startAt: Date?
    public let endAt: Date?

    public init(
        allMuted: Bool,
        modeRawValue: String? = nil,
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.allMuted = allMuted
        self.modeRawValue = modeRawValue
        self.startAt = startAt
        self.endAt = endAt
    }

    public init(
        allMuted: Bool,
        mode: GroupMuteMode,
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.init(
            allMuted: allMuted,
            modeRawValue: mode.rawValue,
            startAt: startAt,
            endAt: endAt
        )
    }
}

public struct GroupMuteModeProjection: Equatable, Sendable {
    public let mode: GroupMuteMode?
    public let allMuted: Bool
    // Render-only. Final send guards must consume server all_muted_active.
    public let presentationActive: Bool
    public let lifecycle: GroupMuteLifecycle
    // Render-only. Final refetch scheduling must consume server next_boundary_at.
    public let presentationNextBoundaryAt: Date?
    public let repairRequired: Bool
}

public struct GroupMuteModeTransition: Equatable, Sendable {
    public let state: GroupMuteModeState
    public let error: GroupMuteModeValidationError?
}

public struct PersistedGroupMuteModeProjection: Equatable, Sendable {
    public let state: GroupMuteModeState?
    public let projection: GroupMuteModeProjection
    public let error: GroupMuteModeValidationError?
}

public struct GroupMuteModeState: Equatable, Sendable {
    public let mode: GroupMuteMode
    public let allMuted: Bool
    public let startAt: Date?
    public let endAt: Date?

    private init(
        mode: GroupMuteMode,
        allMuted: Bool,
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.mode = mode
        self.allMuted = allMuted
        self.startAt = startAt
        self.endAt = endAt
    }

    public static func normalize(_ intent: GroupMuteModeIntent) throws -> GroupMuteModeState {
        if intent.modeRawValue == nil {
            return try normalizeLegacy(intent)
        }
        guard let mode = GroupMuteMode(rawValue: intent.modeRawValue ?? "") else {
            throw GroupMuteModeValidationError.invalidMode
        }

        switch mode {
        case .off:
            guard !intent.allMuted, intent.startAt == nil, intent.endAt == nil else {
                throw GroupMuteModeValidationError.badRequest
            }
            return GroupMuteModeState(mode: .off, allMuted: false)
        case .always:
            guard intent.allMuted, intent.startAt == nil, intent.endAt == nil else {
                throw GroupMuteModeValidationError.badRequest
            }
            return GroupMuteModeState(mode: .always, allMuted: true)
        case .scheduled:
            guard intent.allMuted else {
                throw GroupMuteModeValidationError.badRequest
            }
            let window = try validatedWindow(startAt: intent.startAt, endAt: intent.endAt)
            return GroupMuteModeState(
                mode: .scheduled,
                allMuted: true,
                startAt: window.startAt,
                endAt: window.endAt
            )
        }
    }

    private static func normalizeLegacy(
        _ intent: GroupMuteModeIntent
    ) throws -> GroupMuteModeState {
        guard intent.allMuted else {
            guard intent.startAt == nil, intent.endAt == nil else {
                throw GroupMuteModeValidationError.badRequest
            }
            return GroupMuteModeState(mode: .off, allMuted: false)
        }
        guard intent.startAt != nil || intent.endAt != nil else {
            return GroupMuteModeState(mode: .always, allMuted: true)
        }
        let window = try validatedWindow(startAt: intent.startAt, endAt: intent.endAt)
        return GroupMuteModeState(
            mode: .scheduled,
            allMuted: true,
            startAt: window.startAt,
            endAt: window.endAt
        )
    }

    private static func validatedWindow(
        startAt: Date?,
        endAt: Date?
    ) throws -> (startAt: Date, endAt: Date) {
        guard let startAt, let endAt,
              startAt.timeIntervalSince1970.isFinite,
              endAt.timeIntervalSince1970.isFinite,
              endAt > startAt else {
            throw GroupMuteModeValidationError.invalidWindow
        }
        return (startAt, endAt)
    }

    public func transition(to intent: GroupMuteModeIntent) -> GroupMuteModeTransition {
        do {
            return GroupMuteModeTransition(
                state: try GroupMuteModeState.normalize(intent),
                error: nil
            )
        } catch let error as GroupMuteModeValidationError {
            return GroupMuteModeTransition(state: self, error: error)
        } catch {
            return GroupMuteModeTransition(state: self, error: .badRequest)
        }
    }

    public func projection(atServerTime serverTime: Date) throws -> GroupMuteModeProjection {
        guard serverTime.timeIntervalSince1970.isFinite else {
            throw GroupMuteModeValidationError.badRequest
        }

        switch mode {
        case .off:
            return GroupMuteModeProjection(
                mode: mode,
                allMuted: false,
                presentationActive: false,
                lifecycle: .off,
                presentationNextBoundaryAt: nil,
                repairRequired: false
            )
        case .always:
            return GroupMuteModeProjection(
                mode: mode,
                allMuted: true,
                presentationActive: true,
                lifecycle: .alwaysActive,
                presentationNextBoundaryAt: nil,
                repairRequired: false
            )
        case .scheduled:
            guard let startAt, let endAt else {
                throw GroupMuteModeValidationError.invalidWindow
            }
            if serverTime < startAt {
                return GroupMuteModeProjection(
                    mode: mode,
                    allMuted: true,
                    presentationActive: false,
                    lifecycle: .scheduledPending,
                    presentationNextBoundaryAt: startAt,
                    repairRequired: false
                )
            }
            if serverTime < endAt {
                return GroupMuteModeProjection(
                    mode: mode,
                    allMuted: true,
                    presentationActive: true,
                    lifecycle: .scheduledActive,
                    presentationNextBoundaryAt: endAt,
                    repairRequired: false
                )
            }
            return GroupMuteModeProjection(
                mode: mode,
                allMuted: true,
                presentationActive: false,
                lifecycle: .scheduledEnded,
                presentationNextBoundaryAt: nil,
                repairRequired: false
            )
        }
    }

    public static func projectPersisted(
        _ intent: GroupMuteModeIntent,
        atServerTime serverTime: Date
    ) throws -> PersistedGroupMuteModeProjection {
        let state: GroupMuteModeState
        do {
            state = try normalize(intent)
        } catch let error as GroupMuteModeValidationError {
            return repairProjection(intent: intent, error: error)
        } catch {
            return repairProjection(intent: intent, error: .badRequest)
        }
        return PersistedGroupMuteModeProjection(
            state: state,
            projection: try state.projection(atServerTime: serverTime),
            error: nil
        )
    }

    private static func repairProjection(
        intent: GroupMuteModeIntent,
        error: GroupMuteModeValidationError
    ) -> PersistedGroupMuteModeProjection {
        PersistedGroupMuteModeProjection(
            state: nil,
            projection: GroupMuteModeProjection(
                mode: nil,
                allMuted: intent.allMuted,
                presentationActive: intent.allMuted,
                lifecycle: .repairRequired,
                presentationNextBoundaryAt: nil,
                repairRequired: true
            ),
            error: error
        )
    }
}
// WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END
