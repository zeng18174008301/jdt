import Combine
import XCTest
@testable import BlueStoneIM

final class DeviceRevocationDetectorTests: XCTestCase {
    func testMatchesDeviceDisabledHTTPEnvelope() {
        let error = APIEnvelopeError(
            code: "forbidden",
            message: "forbidden: device disabled"
        )

        XCTAssertTrue(DeviceRevocationDetector.matches(error: error))
    }

    func testMatchesDeviceBindingViolationRealtimeError() {
        let envelope = RealtimeEnvelope(
            type: "error",
            requestID: "req-1",
            payload: [
                "error": .object([
                    "code": .string("forbidden"),
                    "message": .string("device binding violation")
                ])
            ]
        )

        XCTAssertTrue(DeviceRevocationDetector.matches(envelope: envelope))
    }

    func testMatchesDeviceKickedRealtimeErrorPayload() {
        let envelope = RealtimeEnvelope(
            type: "error",
            requestID: "req-kick",
            payload: [
                "code": .string("device_kicked"),
                "reason_code": .string("device_kicked"),
                "message": .string(DeviceRevocationDetector.logoutMessage)
            ]
        )

        XCTAssertTrue(DeviceRevocationDetector.matches(envelope: envelope))
    }

    func testMatchesDeviceRevokedHTTPEnvelope() {
        let error = APIEnvelopeError(
            code: "device_revoked",
            message: "current device session revoked"
        )

        XCTAssertTrue(DeviceRevocationDetector.matches(error: error))
    }

    func testMatchesBusinessForbiddenDeviceBanned() {
        let body = APIEnvelopeError(
            code: "forbidden",
            message: "forbidden: device banned"
        )
        let error = IMAPIError.businessForbidden(
            code: "forbidden",
            message: "forbidden: device banned",
            error: body
        )

        XCTAssertTrue(DeviceRevocationDetector.matches(error: error))
    }

    func testDoesNotMatchWorkspaceMemberDisabled() {
        let error = APIEnvelopeError(
            code: "tenant_member_disabled",
            message: "当前企业成员关系已停用"
        )

        XCTAssertFalse(DeviceRevocationDetector.matches(error: error))
    }
}

@MainActor
final class MainTabSelectionTests: XCTestCase {
    func testTwentyRoundsChangeSelectionSynchronouslyAndCompleteAppearanceTiming() {
        var now: CFAbsoluteTime = 100
        let selection = MainTabSelectionState(now: { now })

        for round in 0..<20 {
            XCTAssertTrue(selection.select(.contacts, source: "test-\(round)-contacts"))
            XCTAssertEqual(selection.activeTab, .contacts)
            now += 0.004
            selection.noteContentAppeared(.contacts)

            XCTAssertTrue(selection.select(.chats, source: "test-\(round)-chats"))
            XCTAssertEqual(selection.activeTab, .chats)
            now += 0.003
            selection.noteContentAppeared(.chats)
        }

        XCTAssertEqual(selection.selectionRevision, 40)
        XCTAssertEqual(selection.completedTransitionCount, 40)
        XCTAssertEqual(selection.lastStateChangeElapsedMilliseconds, 0)
        XCTAssertEqual(selection.lastContentAppearanceElapsedMilliseconds, 3)
        XCTAssertEqual(selection.maximumContentAppearanceElapsedMilliseconds, 4)
    }

    func testTabSelectionDoesNotPublishTheEntireAppState() {
        let state = AppState()
        var appStatePublicationCount = 0
        let publication = state.objectWillChange.sink {
            appStatePublicationCount += 1
        }

        for _ in 0..<20 {
            state.activeTab = .contacts
            XCTAssertEqual(state.activeTab, .contacts)
            state.activeTab = .chats
            XCTAssertEqual(state.activeTab, .chats)
        }

        XCTAssertEqual(state.mainTabSelection.selectionRevision, 40)
        XCTAssertEqual(appStatePublicationCount, 0)
        withExtendedLifetime(publication) {}
    }

    func testTabAccessibilityIdentifiersAndLabelsAreStableAndActionable() {
        let identifiers = MainTab.allCases.map(\.tabAccessibilityIdentifier)

        XCTAssertEqual(Set(identifiers).count, MainTab.allCases.count)
        XCTAssertEqual(MainTab.chats.tabAccessibilityIdentifier, "main_tab_chats")
        XCTAssertEqual(MainTab.contacts.tabAccessibilityIdentifier, "main_tab_contacts")
        XCTAssertEqual(MainTab.chats.tabAccessibilityLabel(displayTitle: "会话"), "会话标签页")
        XCTAssertEqual(MainTab.contacts.tabAccessibilityLabel(displayTitle: "伙伴"), "伙伴标签页")
        XCTAssertNotEqual(MainTab.chats.tabAccessibilityLabel(displayTitle: "会话"), "会话")
        XCTAssertNotEqual(MainTab.contacts.tabAccessibilityLabel(displayTitle: "伙伴"), "伙伴")
    }
}
