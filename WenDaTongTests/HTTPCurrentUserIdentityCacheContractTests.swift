// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_BEGIN
import Foundation
import XCTest
import IM4Data
@testable import WenDaTong

extension HTTPTransportTests {
    func testCurrentUserIdentityDataRecordPreservesLegacySchemaScopeAndFailedWrite() throws {
        captureA43RuntimeLoadedImages()
        let suite = "identity-cache-contract-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "im2.ios.currentUserIdentities"
        let canonicalScope = "identity-tenant|identity-user|jianhuitong-ios"
        var context = makeContext(tenantID: " identity-tenant ", imUID: " identity-user ", imToken: "identity-fixture")
        context.appID = "jianhuitong-ios"; context.accountID = " identity-account "
        let user = IMUser(id: " identity-user ", userID: " public-user ", username: " account-name ",
            name: " Display Name ", title: " Title ", department: " Department ", phone: " 13800138000 ",
            phoneVerified: true, realNameVerified: true, realNameStatus: " verified ",
            email: " identity@example.test ", status: " away ", enterprise: " Enterprise ", avatarSeed: 37,
            avatarURL: " https://images.example.test/avatar.png ", avatarVersion: " v7 ",
            avatarUpdatedAt: " 2026-10-01T00:00:00Z ", badges: ["staff", "verified"])
        let authorityScope = try XCTUnwrap(CurrentProfileAuthorityScope(
            tenantID: "identity-tenant", actorIMUID: "identity-user", appID: "jianhuitong-ios"))
        let checkpoint = CurrentProfileAuthorityCheckpoint(scope: authorityScope, userRevision: 31,
            identityGeneration: 9, nickname: "Authority", avatar: "authority.png")
        let record = IMStoredCurrentUserIdentity(user: user, context: context, scope: canonicalScope,
            profileAuthorityCheckpoint: checkpoint, savedAt: 2_000_000_000)
        let goldenJSON = Data(#"""
        {"scope":"identity-tenant|identity-user|jianhuitong-ios","tenantID":"identity-tenant",
         "imUID":"identity-user","accountID":"identity-account","id":"identity-user","userID":"public-user",
         "username":"account-name","name":"Display Name","title":"Title","department":"Department",
         "phone":"13800138000","phoneVerified":true,"realNameVerified":true,"realNameStatus":"verified",
         "email":"identity@example.test","status":"away","enterprise":"Enterprise","avatarSeed":37,
         "avatarURL":"https://images.example.test/avatar.png","avatarVersion":"v7","avatarUpdatedAt":"2026-10-01T00:00:00Z",
         "badges":["staff","verified"],"profileAuthorityCheckpoint":{"tenantID":"identity-tenant",
           "actorIMUID":"identity-user","appID":"jianhuitong-ios","userRevision":31,"identityGeneration":9,
           "nickname":"Authority","avatar":"authority.png"},"savedAt":2000000000}
        """#.utf8)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: goldenJSON) as? NSDictionary)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? NSDictionary, expected)
        IMCurrentUserIdentityCache.save(user, context: context, profileAuthorityCheckpoint: checkpoint, defaults: defaults)
        let saved = try XCTUnwrap(defaults.data(forKey: storageKey))
        let savedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: [String: Any]])
        var savedFields = try XCTUnwrap(savedRoot[canonicalScope])
        XCTAssertGreaterThan(try XCTUnwrap(savedFields.removeValue(forKey: "savedAt") as? Double), 0)
        let expectedFields = try XCTUnwrap(expected.mutableCopy() as? NSMutableDictionary)
        expectedFields.removeObject(forKey: "savedAt")
        XCTAssertEqual(savedFields as NSDictionary, expectedFields)
        XCTAssertEqual(IMCurrentUserIdentityCache.load(context: context, defaults: defaults)?.authorityCheckpoint, checkpoint)
        let invalid = IMStoredCurrentUserIdentity(user: user, context: context, scope: canonicalScope, savedAt: .nan)
        CurrentUserIdentityRecordStore.persist([canonicalScope: invalid], defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: storageKey), saved, "Failed encoding must preserve the last stored record")
        XCTAssertEqual(IMCurrentUserIdentityCache.load(context: context, defaults: defaults)?.username, "account-name")

        let legacyScope = "identity-tenant|identity-user|identity-account"
        let otherScope = "other-tenant|other-user|jianhuitong-ios"
        var otherContext = context; otherContext.tenantID = "other-tenant"; otherContext.imUID = "other-user"
        let otherRecord = IMStoredCurrentUserIdentity(user: makeUser(id: "other-user", name: "Other"),
            context: otherContext, scope: otherScope, savedAt: 2_000_000_000)
        let legacyRecord = IMStoredCurrentUserIdentity(user: user, context: context, scope: legacyScope,
            profileAuthorityCheckpoint: checkpoint, savedAt: 2_000_000_000)
        CurrentUserIdentityRecordStore.persist([legacyScope: legacyRecord, otherScope: otherRecord], defaults: defaults)
        XCTAssertEqual(IMCurrentUserIdentityCache.load(context: context, defaults: defaults), legacyRecord)
        IMCurrentUserIdentityCache.clear(context: context, defaults: defaults)
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
        XCTAssertEqual(CurrentUserIdentityRecordStore.loadAll(defaults: defaults), [otherScope: otherRecord])
        defaults.set(Data(#"{"broken":}"#.utf8), forKey: storageKey)
        XCTAssertTrue(CurrentUserIdentityRecordStore.loadAll(defaults: defaults).isEmpty)
        XCTAssertNil(IMCurrentUserIdentityCache.load(context: context, defaults: defaults))
        defaults.set("preserved", forKey: "fixture.unrelated")
        IMCurrentUserIdentityCache.clearAll(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: storageKey))
        XCTAssertEqual(defaults.string(forKey: "fixture.unrelated"), "preserved")
    }
}
// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_END
