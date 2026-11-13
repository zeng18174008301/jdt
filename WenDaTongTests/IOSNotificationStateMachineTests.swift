import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

@MainActor
final class IOSNotificationStateMachineTests: XCTestCase {
    func testFirstActiveNotificationAuthorizationPolicyRequestsOnceAndNeverLoopsDenied() {
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .notDetermined, didRequestThisProcess: false),
            .requestAuthorization
        )
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .notDetermined, didRequestThisProcess: true),
            .none
        )
        XCTAssertEqual(
            IOSNotificationAuthorizationPolicy.action(status: .denied, didRequestThisProcess: false),
            .none
        )
        for status in [
            IOSNotificationAuthorizationStatus.authorized,
            .provisional,
            .ephemeral
        ] {
            XCTAssertEqual(
                IOSNotificationAuthorizationPolicy.action(status: status, didRequestThisProcess: false),
                .registerRemoteNotifications
            )
        }
    }

    func testPermissionCoordinatorRequestsNotDeterminedOnceAndKeepsPushKitIndependent() async {
        let deniedManager = RecordingNotificationAuthorizationManager(status: .notDetermined)
        deniedManager.statusAfterRequest = .denied
        let deniedCoordinator = IOSNotificationPermissionCoordinator(manager: deniedManager)

        let firstDeniedStatus = await deniedCoordinator.sceneDidBecomeActive()
        let secondDeniedStatus = await deniedCoordinator.sceneDidBecomeActive()
        XCTAssertEqual(firstDeniedStatus, .denied)
        XCTAssertEqual(secondDeniedStatus, .denied)
        XCTAssertEqual(deniedManager.requestCount, 1)
        XCTAssertEqual(deniedManager.registrationCount, 0)

        let authorizedManager = RecordingNotificationAuthorizationManager(status: .authorized)
        let authorizedCoordinator = IOSNotificationPermissionCoordinator(manager: authorizedManager)
        let authorizedStatus = await authorizedCoordinator.sceneDidBecomeActive()
        XCTAssertEqual(authorizedStatus, .authorized)
        XCTAssertEqual(authorizedManager.requestCount, 0)
        XCTAssertEqual(authorizedManager.registrationCount, 1)

        let appDelegateSource = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("WenDaTong/App/WDTApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appDelegateSource?.contains("SystemCallIntegrationPolicy.usesSystemCallIntegration") == true)
        XCTAssertTrue(appDelegateSource?.contains("CallKitPushVoiceCallManager.shared.start()") == true)
    }

    func testLifecyclePolicySeparatesForegroundBackgroundAndTerminatedPresentation() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-42",
            "aggregate_id": "message-42",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope"
        ]))

        XCTAssertEqual(payload.title, "收到新消息通知")
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .foregroundVisible, payload: payload), .inAppWithSound)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .backgroundAlive, payload: payload), .localSystemNotification)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .backgroundSuspended, payload: payload), .systemAPNsNotification)
        XCTAssertEqual(IOSNotificationStatePolicy.action(processState: .terminated, payload: payload), .systemAPNsNotification)
    }

    func testNotificationDeliveryKeepsExecutableBackgroundLocalAndSuspendedAPNsPathsDistinct() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-background-1",
            "aggregate_id": "conversation-background-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope"
        ]))

        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .backgroundAlive, payload: payload),
            .localSystemNotification,
            "only an executing background process may create the local system notification"
        )
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .backgroundSuspended, payload: payload),
            .systemAPNsNotification,
            "a suspended process must rely on APNs rather than assume local code can run"
        )
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(processState: .terminated, payload: payload),
            .systemAPNsNotification
        )
    }

    func testOpaqueNotificationTargetAndMentionAttentionRemainPrivacyMinimal() throws {
        let payload = try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "message-opaque",
            "aggregate_id": "aggregate-opaque",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": "tenant-scope",
            "target_ref": "target-ref-opaque",
            "attention": "mention",
            "sender_name": "must-not-be-used",
            "body": "must-not-be-used"
        ]))

        XCTAssertEqual(payload.targetRef, "target-ref-opaque")
        XCTAssertEqual(payload.attention, .mention)
        XCTAssertEqual(payload.title, "收到新消息通知")
        XCTAssertNil(payload.localMetadata)
    }

    func testVoIPTransportPolicyOnlyAllowsTrueRingingInvitation() throws {
        let ringing = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "ringing",
            "call_id": "call-ringing"
        ]))
        let terminal = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "answered_elsewhere",
            "call_id": "call-terminal"
        ]))

        XCTAssertEqual(VoIPPushTransportPolicy.action(for: ringing), .reportIncomingCall)
        XCTAssertEqual(VoIPPushTransportPolicy.action(for: terminal), .ignoreAndReconcile)
    }

    func testCallCopyIsExactAndTerminalEventCancelsWithoutAlert() throws {
        func payload(category: String, presentation: String) throws -> IOSNotificationStatePayload {
            try XCTUnwrap(IOSNotificationStatePayload(dictionary: [
                "schema_version": "notification_state.v1",
                "notification_id": "call-event-7",
                "aggregate_id": "call-7",
                "notification_category": category,
                "presentation": presentation,
                "scope_key": "tenant-scope",
                "type": "rtc_call",
                "event": presentation == "cancel" ? "ended" : "ringing",
                "call_id": "call-7",
                "call_type": category == "video_call" ? "video" : "audio"
            ]))
        }

        XCTAssertEqual(try payload(category: "voice_call", presentation: "alert").title, "收到语音通话请求")
        XCTAssertEqual(try payload(category: "video_call", presentation: "alert").title, "收到视频通话请求")
        XCTAssertEqual(
            IOSNotificationStatePolicy.action(
                processState: .backgroundAlive,
                payload: try payload(category: "video_call", presentation: "cancel")
            ),
            .cancelExisting
        )
        XCTAssertNil(IOSNotificationStatePayload(dictionary: [
            "schema_version": "notification_state.v1",
            "notification_id": "incomplete"
        ]))
    }

    func testNotificationPrivacyAuthorityFailsClosedForUnknownAndConflictingCallFields() {
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ringing",
                callType: "audio",
                callID: "voice-1"
            ),
            .voiceCallRequest
        )
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ringing",
                callType: "video",
                callID: "video-1"
            ),
            .videoCallRequest
        )
        for callType in ["", "legacy-video-ish", "语音"] {
            XCTAssertEqual(
                IOSNotificationPrivacyCopy.authoritativeCallRequest(
                    payloadType: "rtc_call",
                    eventType: "ringing",
                    callType: callType,
                    callID: "unknown-1"
                ),
                .generic
            )
        }
        XCTAssertEqual(
            IOSNotificationPrivacyCopy.authoritativeCallRequest(
                payloadType: "rtc_call",
                eventType: "ended",
                callType: "video",
                callID: "ended-1"
            ),
            .generic
        )
    }

    func testLocalNotificationVisibleSurfacesUseOnlyFixedPrivacyCopy() {
        for (kind, expected) in [
            (IOSNotificationPrivacyKind.generic, "收到新消息通知"),
            (.voiceCallRequest, "收到语音通话请求"),
            (.videoCallRequest, "收到视频通话请求")
        ] {
            let content = IOSNotificationRuntime.visibleContent(for: kind)
            XCTAssertEqual(content.title, "问达通")
            XCTAssertEqual(content.body, expected)
            XCTAssertEqual(content.subtitle, "")
            XCTAssertEqual(content.threadIdentifier, "")
            XCTAssertEqual(content.summaryArgument, "")
        }
    }

    func testLocalNotificationMetadataMatchesExactReadWatermarkAndExcludesPrivateFields() throws {
        let record = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: " tenant-a ",
            imUID: " user-a ",
            appID: " app-ios ",
            channelID: " c1 ",
            channelType: " Direct ",
            channelSeq: 7,
            createdAt: "2026-08-26T00:00:00Z"
        ))
        let matching = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 7
        ))
        let lowerWatermark = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 6
        ))
        let otherApp = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "other-app",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 9
        ))

        XCTAssertTrue(record.matches(matching))
        XCTAssertFalse(record.matches(lowerWatermark))
        XCTAssertFalse(record.matches(otherApp))
        XCTAssertNil(IOSNotificationLocalMetadata(
            notificationID: "message-0",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 0
        ))
        XCTAssertNil(IOSNotificationLocalMetadata(
            notificationID: " ",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 1
        ))
        let forbiddenKeys = Set([
            "body", "text", "message", "sender_name", "profile", "avatar", "device_id", "source_device"
        ])
        XCTAssertTrue(forbiddenKeys.isDisjoint(with: Set(record.userInfo.keys)))
    }

    func testRuntimeCancelReadWatermarkRemovesPendingDeliveredIdentifiersAndPrunesIndex() throws {
        let matched = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-5",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 5
        ))
        let later = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-8",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 8
        ))
        let otherTenant = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-other",
            aggregateID: "conversation-1",
            tenantID: "tenant-b",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 4
        ))
        let store = RecordingIOSNotificationLocalIndexStore(records: [matched, later, otherTenant])
        let center = RecordingIOSNotificationCenter()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        let watermark = try XCTUnwrap(IOSNotificationReadWatermark(
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            lastReadSeq: 5
        ))

        let removed = runtime.cancelLocalNotifications(matching: watermark)

        XCTAssertEqual(Set(removed), Set([matched.requestIdentifier, "message-5"]))
        XCTAssertEqual(center.pendingRemovals.map(Set.init), [Set(removed)])
        XCTAssertEqual(center.deliveredRemovals.map(Set.init), [Set(removed)])
        XCTAssertEqual(store.records, [later, otherTenant])
    }

    func testRealtimeLocalNotificationPersistsDeterministicPrivacyMinimalMetadata() throws {
        let metadata = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 7
        ))
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)

        runtime.presentRealtimeMessage(
            eventID: "message-7",
            backgrounded: true,
            localMetadata: metadata
        )

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.identifier, metadata.requestIdentifier)
        XCTAssertEqual(store.records, [metadata])
        XCTAssertEqual(request.content.title, "问达通")
        XCTAssertEqual(request.content.body, "收到新消息通知")
        XCTAssertEqual(request.content.userInfo["channel_seq"] as? String, "7")
        XCTAssertNil(request.content.userInfo["body"])
        XCTAssertNil(request.content.userInfo["sender_name"])
        XCTAssertNil(request.content.userInfo["source_device"])
    }

    func testRealtimeLocalNotificationTapEmitsConversationOpenPayloadFromMetadata() throws {
        let metadata = try XCTUnwrap(IOSNotificationLocalMetadata(
            notificationID: "message-7",
            aggregateID: "conversation-1",
            tenantID: "tenant-a",
            imUID: "user-a",
            appID: "app-ios",
            channelID: "c1",
            channelType: "direct",
            channelSeq: 7
        ))
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }

        runtime.presentRealtimeMessage(
            eventID: "message-7",
            backgrounded: true,
            localMetadata: metadata
        )

        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.content.userInfo["schema_version"] as? String, "notification_local.v1")
        XCTAssertTrue(runtime.handleNotificationResponse(request.content.userInfo))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened from realtime local notification tap")
        }
        XCTAssertEqual(opened.category, "message")
        XCTAssertEqual(opened.channelID, "c1")
        XCTAssertEqual(opened.channelType, "direct")
        XCTAssertEqual(opened.channelSeq, 7)
        XCTAssertEqual(opened.scopeKey, IOSNotificationRuntime.scopeKey(tenantID: "tenant-a"))
        XCTAssertEqual(opened.targetRef, "")
    }

    func testBackgroundLocalNotificationTapPreservesConversationOpenPayload() throws {
        let center = RecordingIOSNotificationCenter()
        let store = RecordingIOSNotificationLocalIndexStore()
        let runtime = IOSNotificationRuntime(notificationCenter: center, localIndexStore: store)
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "message-background-tap-1",
            "aggregate_id": "conversation-background-tap-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-a"),
            "target_ref": "opaque-target-ref-1",
            "tenant_id": "tenant-a",
            "im_uid": "user-a",
            "app_id": "app-ios",
            "channel_id": "conversation-background-tap-1",
            "channel_type": "direct",
            "channel_seq": "11"
        ]

        XCTAssertEqual(
            runtime.handleRemoteNotification(payload, processState: .backgroundAlive),
            .localSystemNotification
        )
        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.content.userInfo["schema_version"] as? String, "notification_state.v1")
        XCTAssertEqual(request.content.userInfo["target_ref"] as? String, "opaque-target-ref-1")
        XCTAssertEqual(request.content.userInfo["channel_seq"] as? String, "11")

        XCTAssertTrue(runtime.handleNotificationResponse(request.content.userInfo))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened from local notification tap")
        }
        XCTAssertEqual(opened.targetRef, "opaque-target-ref-1")
        XCTAssertEqual(opened.channelID, "conversation-background-tap-1")
        XCTAssertEqual(opened.channelSeq, 11)
    }

    func testStandardAPNsRegistrationPreservesRenamedBundleIdentity() {
        let registration = RemoteDeviceRegistration.apns(
            token: "opaque-token",
            bundleID: "com.jianhuitongqiyetest.app",
            environment: "sandbox"
        )
        XCTAssertEqual(registration.pushTokenType, "apns")
        XCTAssertEqual(registration.bundleID, "com.jianhuitongqiyetest.app")
        XCTAssertEqual(registration.requestBody["push_token_type"] as? String, "apns")
    }

    func testPushTokenInvalidationDoesNotDeleteSharedDeviceRowAndScopeRetirementIsSerialized() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appSourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong")
        let appState = try String(
            contentsOf: appSourceRoot.appendingPathComponent("Core/AppSupport/Calls/AppState+CallSystemEvents.swift"),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: appSourceRoot.appendingPathComponent("App/WDTApp.swift"),
            encoding: .utf8
        )

        let voipInvalidation = try XCTUnwrap(
            appState.range(of: "case .voipTokenInvalidated:")
                .flatMap { start in
                    appState.range(of: "case let .voipPushPayload", range: start.upperBound..<appState.endIndex)
                        .map { appState[start.lowerBound..<$0.lowerBound] }
                }
        )
        XCTAssertTrue(voipInvalidation.contains("resetVoIPPushRegistrationKeys"))
        XCTAssertTrue(voipInvalidation.contains("retireRegisteredPushTokenSlotIfPossible"))
        XCTAssertFalse(voipInvalidation.contains("disableDevice"))
        XCTAssertFalse(voipInvalidation.contains("retirePushDevices"))

        let standardInvalidation = try XCTUnwrap(
            appState.range(of: "case let .standardRegistrationInvalidated(registration):")
                .flatMap { start in
                    appState.range(of: "case let .notificationOpened", range: start.upperBound..<appState.endIndex)
                        .map { appState[start.lowerBound..<$0.lowerBound] }
                }
        )
        XCTAssertTrue(standardInvalidation.contains("resetStandardPushRegistrationKeys"))
        XCTAssertTrue(standardInvalidation.contains("retireRegisteredPushTokenSlotIfPossible"))
        XCTAssertFalse(standardInvalidation.contains("disableDevice"))
        XCTAssertFalse(standardInvalidation.contains("retirePushDevices"))

        XCTAssertTrue(appState.contains("await retirementTask?.value"))
        XCTAssertTrue(appState.contains("await previousRegistrationTask?.value"))
        XCTAssertTrue(appState.contains("await standardRegistration?.value"))
        XCTAssertTrue(appState.contains("await voipRegistration?.value"))
        XCTAssertTrue(appState.contains("retirePushTokenWithTransientRetry"))
        XCTAssertTrue(appState.contains("provider: .apnsVoIP"))
        XCTAssertFalse(appState.contains("for deviceID in deviceIDs.union(lateStandardDeviceIDs).union(lateVoIPDeviceIDs)"))
        XCTAssertTrue(appDelegate.contains("SystemCallIntegrationPolicy.usesSystemCallIntegration"))
        XCTAssertTrue(appDelegate.contains("CallKitPushVoiceCallManager.shared.start()"))
        XCTAssertTrue(appDelegate.contains("didFinishLaunchingWithOptions"))
    }

    func testAPNsEnvironmentUsesSignedConfigurationBeforeBuildFallback() {
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "development", debugFallback: false), "sandbox")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "production", debugFallback: true), "production")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: "", debugFallback: true), "sandbox")
        XCTAssertEqual(IOSAPNsEnvironmentPolicy.resolve(infoValue: nil, debugFallback: false), "production")
    }

    func testNotificationBadgeCountClampsNegativeStateToZero() {
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(-3), 0)
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(0), 0)
        XCTAssertEqual(IOSNotificationRuntime.normalizedBadgeCount(101), 101)
    }

    func testStandardTokenInvalidationCarriesTheExactRetiredToken() throws {
        let runtime = IOSNotificationRuntime()
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }

        runtime.updateStandardToken(Data([0x01, 0x02, 0xA0]))
        runtime.invalidateStandardToken()

        guard case let .standardRegistrationInvalidated(registration) = try XCTUnwrap(received.last) else {
            return XCTFail("expected exact invalidated standard registration")
        }
        XCTAssertEqual(registration.pushToken, "0102a0")
        XCTAssertEqual(registration.tokenFingerprint?.count, 64)
        XCTAssertNil(runtime.standardRegistration)
    }

    func testNotificationOpenIsDeliveredIndependentlyFromPresentationDedup() throws {
        // WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_BEGIN
        let runtime = IOSNotificationRuntime(
            notificationCenter: RecordingIOSNotificationCenter(),
            localIndexStore: RecordingIOSNotificationLocalIndexStore()
        )
        // WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_END
        var received: [IOSNotificationRuntimeEvent] = []
        let observer = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(observer) }
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "message-open-42",
            "aggregate_id": "message-open-42",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        ]

        XCTAssertTrue(runtime.accept(eventID: "message-open-42"))
        XCTAssertTrue(runtime.handleNotificationResponse(payload))
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.last) else {
            return XCTFail("expected notificationOpened")
        }
        XCTAssertEqual(opened.aggregateID, "message-open-42")
    }

    func testColdNotificationOpenSurvivesMissingAndStaleObserversUntilLiveConsumerBinds() throws {
        // WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_BEGIN
        let runtime = IOSNotificationRuntime(
            notificationCenter: RecordingIOSNotificationCenter(),
            localIndexStore: RecordingIOSNotificationLocalIndexStore()
        )
        // WDT_IOS1_NOTIFICATION_OPEN_RECORDING_20261112_END
        let payload: [AnyHashable: Any] = [
            "schema_version": "notification_state.v1",
            "notification_id": "cold-open-1",
            "aggregate_id": "conversation-1",
            "notification_category": "message",
            "presentation": "alert",
            "scope_key": IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        ]

        XCTAssertTrue(runtime.handleNotificationResponse(payload))
        let staleObserver = runtime.observe { _ in false }
        runtime.removeObserver(staleObserver)

        var received: [IOSNotificationRuntimeEvent] = []
        let liveObserver = runtime.observe {
            received.append($0)
            return true
        }
        defer { runtime.removeObserver(liveObserver) }

        XCTAssertEqual(received.count, 1)
        guard case let .notificationOpened(opened) = try XCTUnwrap(received.first) else {
            return XCTFail("expected notificationOpened")
        }
        XCTAssertEqual(opened.aggregateID, "conversation-1")
    }

    func testNotificationScopeMatchesServerSHA256PrefixContract() {
        XCTAssertEqual(IOSNotificationRuntime.scopeKey(tenantID: "tenant-42").count, 24)
        XCTAssertEqual(
            IOSNotificationRuntime.scopeKey(tenantID: " tenant-42 "),
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-42")
        )
        XCTAssertNotEqual(
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-42"),
            IOSNotificationRuntime.scopeKey(tenantID: "tenant-43")
        )
    }

    func testForegroundStateAcceptsExactEventOnlyOnceForOneSound() {
        let eventID = "notification-state-sound-once"
        XCTAssertTrue(IOSNotificationRuntime.shared.accept(eventID: eventID))
        XCTAssertFalse(IOSNotificationRuntime.shared.accept(eventID: eventID))
    }

    func testRTCCallEventCarriesExactNotificationAckIdentity() throws {
        let event = try JSONDecoder().decode(
            RemoteRTCCallEvent.self,
            from: Data(#"{"id":"event-7","notification_id":"rtc_call:call-7:1:ringing","event":"rtc.call.ringing"}"#.utf8)
        )
        XCTAssertEqual(event.notificationID, "rtc_call:call-7:1:ringing")
    }
}

@MainActor
private final class RecordingIOSNotificationCenter: IOSNotificationCenterManaging {
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var pendingRemovals: [[String]] = []
    private(set) var deliveredRemovals: [[String]] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pendingRemovals.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredRemovals.append(identifiers)
    }
}

@MainActor
private final class RecordingNotificationAuthorizationManager: IOSNotificationAuthorizationManaging {
    var status: IOSNotificationAuthorizationStatus
    var statusAfterRequest: IOSNotificationAuthorizationStatus?
    private(set) var requestCount = 0
    private(set) var registrationCount = 0

    init(status: IOSNotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> IOSNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if let statusAfterRequest {
            status = statusAfterRequest
        }
        return status.permitsRemoteNotificationRegistration
    }

    func registerForRemoteNotifications() {
        registrationCount += 1
    }
}

@MainActor
private final class RecordingIOSNotificationLocalIndexStore: IOSNotificationLocalIndexStoring {
    var records: [IOSNotificationLocalMetadata]

    init(records: [IOSNotificationLocalMetadata] = []) {
        self.records = records
    }

    func loadRecords() -> [IOSNotificationLocalMetadata] {
        records
    }

    func saveRecords(_ records: [IOSNotificationLocalMetadata]) {
        self.records = records
    }
}
