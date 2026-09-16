import XCTest
@testable import BlueStoneIM

final class CertificationPresentationTests: XCTestCase {
    private let scope = CertificationPresentationScope(
        tenantID: "tenant-a",
        viewerID: "viewer-a",
        appID: "app1",
        subjectUID: "WXT00000001",
        sessionID: "session-a",
        sessionGeneration: 3
    )

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
