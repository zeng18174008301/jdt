@testable import IM4Features
import UIKit
import SwiftUI // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
import XCTest
@testable import WenDaTong

final class CertificationPresentationTests: XCTestCase {
    private let scope = CertificationPresentationScope(
        tenantID: "tenant-a",
        viewerID: "viewer-a",
        appID: "app1",
        subjectUID: "WXT00000001",
        sessionID: "session-a",
        sessionGeneration: 3
    )

    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedAvatarObservesOnlyExactCertificationAndClearsOnReuse() async throws {
        let summary = try makeSummary(generation: 7, revision: 3, label: "企业导师")
        let certification = try XCTUnwrap(summary.certification)
        let presentation = try XCTUnwrap(CertificationPresentation(certification: certification, generation: 7))
        let store = CertificationPresentationStore()
        var presentations: [String: CertificationPresentation] = [:]
        var requestedUIDs: [String] = []
        var lookedUpUIDs: [String] = []
        let source = CertificationPillSource(
            changes: store.changes,
            scopeRevision: { store.scopeRevision },
            presentation: { uid in
                lookedUpUIDs.append(uid)
                return presentations[uid]
            },
            ensure: { requestedUIDs.append($0) }
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let host = UIHostingController(
            rootView: AvatarView(name: "成员", seed: 0x5D6BFF, certificationReference: source.reference(forExactUID: "peer"))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func snapshot() async throws -> Data {
            try await Task.sleep(nanoseconds: 250_000_000)
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.pngData())
        }

        let plain = try await snapshot()
        presentations["unrelated"] = presentation
        store.advance()
        let unchanged = try await snapshot()
        XCTAssertEqual(unchanged, plain)

        presentations["peer"] = presentation
        store.advance()
        let certified = try await snapshot()
        XCTAssertNotEqual(certified, plain)

        presentations.removeValue(forKey: "peer")
        store.advance(scopeChanged: true)
        let cleared = try await snapshot()
        XCTAssertEqual(cleared, plain)

        presentations["peer"] = presentation
        store.advance()
        let restored = try await snapshot()
        XCTAssertNotEqual(restored, plain)

        host.rootView = AvatarView(
            name: "成员", seed: 0x5D6BFF,
            certificationReference: source.reference(forExactUID: "new-peer")
        )
        let reused = try await snapshot()
        XCTAssertEqual(reused, plain)
        XCTAssertEqual(Set(lookedUpUIDs), ["peer", "new-peer"])
        XCTAssertTrue(requestedUIDs.isEmpty)
    }
    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

    func testPresentationUsesTwoFixedSlotsAndEnterpriseAccessibility() throws {
        let summary = try makeSummary(generation: 7, revision: 3, label: "企业导师")
        let certification = try XCTUnwrap(summary.certification)
        let presentation = try XCTUnwrap(
            CertificationPresentation(
                certification: certification,
                generation: 7
            )
        )

        XCTAssertEqual(presentation.visibleLabel, "企业导师")
        XCTAssertEqual(presentation.accessibilityLabel, "由本企业认证：企业导师")
        XCTAssertEqual(presentation.avatarDecoration.slot, .avatarLowerRight)
        XCTAssertEqual(
            presentation.pillDecoration(compact: false).decoration.slot,
            .afterNameCertificationPill
        )
        XCTAssertEqual(
            presentation.pillDecoration(compact: false).placement,
            .afterName
        )
        XCTAssertEqual(
            presentation.pillDecoration(compact: true).placement,
            .belowName
        )
        XCTAssertEqual(
            presentation.identityDecorations.map(\.slot),
            [.avatarLowerRight, .afterNameCertificationPill]
        )
    }

    func testInvalidStyleMissingGenerationAndUnsafeLabelFailClosed() throws {
        let unsupported = try makeSummary(
            generation: 7,
            revision: 3,
            label: "企业导师",
            style: "merchant-blue"
        )
        XCTAssertNil(
            CertificationPresentation(
                certification: try XCTUnwrap(unsupported.certification),
                generation: 7
            )
        )
        let unsafe = try makeSummary(
            generation: 7,
            revision: 3,
            label: "企业\u{202e}导师"
        )
        XCTAssertNil(
            CertificationPresentation(
                certification: try XCTUnwrap(unsafe.certification),
                generation: 7
            )
        )

        var state = CertificationPresentationState(scope: scope)
        let missingGeneration = try makeSummary(
            generation: nil,
            revision: 3,
            label: "企业导师"
        )
        XCTAssertEqual(
            state.apply(
                summary: missingGeneration,
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .purgedForRefetch
        )
        XCTAssertNil(state.presentation)
        XCTAssertTrue(state.needsRefetch)
    }

    func testNewerOmissionClearsAndOlderCertifiedSummaryCannotRestore() throws {
        var state = CertificationPresentationState(scope: scope)
        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 7, revision: 3, label: "企业导师"),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .applied
        )
        XCTAssertEqual(state.presentation?.visibleLabel, "企业导师")

        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 8, revision: nil, label: nil),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .cleared
        )
        XCTAssertNil(state.presentation)
        XCTAssertEqual(state.generation, 8)

        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 7, revision: 3, label: "企业导师"),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .ignoredStale
        )
        XCTAssertNil(state.presentation)
        XCTAssertEqual(state.generation, 8)

        XCTAssertEqual(state.invalidate(generation: 9, revision: 4), .invalidated)
        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 9, revision: 4, label: "新认证"),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .applied
        )
        XCTAssertEqual(state.presentation?.visibleLabel, "新认证")
    }

    func testGenerationZeroCanAuthoritativelyRepresentNoCertification() throws {
        var state = CertificationPresentationState(scope: scope)
        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 0, revision: nil, label: nil),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .cleared
        )
        XCTAssertEqual(state.generation, 0)
        XCTAssertNil(state.presentation)
        XCTAssertFalse(state.needsRefetch)
    }

    func testInvalidationKeepsLastKnownGoodAndScopeChangeClears() throws {
        var state = CertificationPresentationState(scope: scope)
        _ = state.apply(
            summary: try makeSummary(generation: 7, revision: 3, label: "企业导师"),
            responseScope: scope,
            subjectTenantID: "tenant-a",
            fresh: true
        )
        XCTAssertEqual(state.invalidate(generation: 8), .invalidated)
        XCTAssertEqual(state.presentation?.visibleLabel, "企业导师")
        XCTAssertTrue(state.needsRefetch)
        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 8, revision: 4, label: "企业导师"),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .applied
        )
        XCTAssertEqual(state.presentation?.revision, 4)
        XCTAssertFalse(state.needsRefetch)

        let nextScope = CertificationPresentationScope(
            tenantID: "tenant-b",
            viewerID: "viewer-a",
            appID: "app1",
            subjectUID: "WXT00000001",
            sessionID: "session-b",
            sessionGeneration: 4
        )
        XCTAssertEqual(state.setScope(nextScope), .cleared)
        XCTAssertNil(state.presentation)
        XCTAssertEqual(state.generation, 0)
        XCTAssertEqual(
            state.apply(
                summary: try makeSummary(generation: 9, revision: 5, label: "旧标签"),
                responseScope: scope,
                subjectTenantID: "tenant-a",
                fresh: true
            ),
            .ignoredForeign
        )
        XCTAssertNil(state.presentation)
    }

    private func makeSummary(
        generation: Int64?,
        revision: Int64?,
        label: String?,
        style: String = certificationPresentationStyleToken
    ) throws -> UserSummaryV2 {
        try UserSummaryV2(
            userRevision: 9,
            generations: .init(identity: 41, certification: generation),
            imUID: scope.subjectUID,
            userID: scope.subjectUID,
            displayName: "王总",
            displayNameSource: "nickname",
            rawNickname: "王总",
            avatar: .init(
                url: "/avatars/user.png",
                version: "v1",
                source: "uploaded"
            ),
            certification: label.flatMap { label in
                revision.map {
                    UserSummaryV2.Certification(
                        verified: true,
                        label: label,
                        style: style,
                        revision: $0
                    )
                }
            }
        )
    }
}
