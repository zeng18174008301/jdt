import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    func testTenantSearchPartialResponseKeepsHealthyResultsAndMissingTotalsDistinct() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "degraded": true,
          "results_by_type": {
            "contacts": {
              "items": [{"result_id":"contact:u1", "type":"contact", "title":"知"}],
              "count": 1, "total_is_exact": true, "authoritative": true, "status": "ok"
            },
            "messages": {
              "items": [], "total_is_exact": false, "authoritative": false, "status": "unavailable",
              "error": {"code":"query_too_short", "message":"too short", "retryable":false}
            },
            "files": {
              "items": [], "total_is_exact": false, "authoritative": true, "status": "ok",
              "has_more": true, "next_cursor": "20", "next_cursor_v2": "test-token"
            }
          },
          "errors_by_type": {
            "messages": {"code":"query_too_short", "message":"too short", "retryable":false}
          }
        }
        """.utf8))

        XCTAssertTrue(response.degraded)
        XCTAssertEqual(response.resultsByType["contacts"]?.items.first?.title, "知")
        XCTAssertEqual(response.resultsByType["contacts"]?.exactTotal, 1)
        XCTAssertEqual(response.resultsByType["messages"]?.status, "unavailable")
        XCTAssertEqual(response.resultsByType["messages"]?.authoritative, false)
        XCTAssertEqual(response.resultsByType["messages"]?.error, response.errorsByType["messages"])
        XCTAssertEqual(response.errorsByType["messages"]?.code, "query_too_short")
        XCTAssertNil(response.resultsByType["messages"]?.exactTotal)
        XCTAssertNil(response.resultsByType["files"]?.exactTotal)
        XCTAssertEqual(response.resultsByType["files"]?.nextCursorV2, "test-token")
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    func testTenantSearchResponseDecodesLegacyArrayBucketsAndPinyinHighlights() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "zss",
          "scope": "global",
          "types": ["contacts"],
          "limit": 10,
          "results_by_type": {
            "contacts": [
              {
                "result_id": "contact:u_1",
                "type": "contact",
                "title": "张三石",
                "subtitle": "拼音命中",
                "highlight_ranges": [
                  {"field":"title","start":0,"length":3}
                ],
                "source": {"name":"tenant.contacts"}
              }
            ]
          }
        }
        """.utf8))

        let contactBucket = try XCTUnwrap(response.resultsByType["contacts"])
        XCTAssertEqual(contactBucket.count, 1)
        XCTAssertFalse(contactBucket.hasMore)
        XCTAssertEqual(contactBucket.items.first?.highlightRanges.first, RemoteTenantSearchHighlightRange(field: "title", start: 0, length: 3))
        XCTAssertEqual(contactBucket.items.first?.sourceName, "tenant.contacts")
    }

    func testConversationSearchPaginationKeepsMessagesAndFilesCursorsSeparate() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:msg-1",
                  "type": "message",
                  "title": "消息命中",
                  "jump_target": {
                    "kind": "message",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 101,
                    "message_id": "msg-1"
                  }
                }
              ],
              "count": 1,
              "has_more": true,
              "next_cursor": "messages-next"
            },
            "files": {
              "items": [
                {
                  "result_id": "file:file-1",
                  "type": "file",
                  "title": "合同.pdf",
                  "jump_target": {
                    "kind": "message_file",
                    "channel_id": "group-1",
                    "channel_type": "group",
                    "channel_seq": 205,
                    "message_id": "msg-file",
                    "file_id": "file-1"
                  }
                }
              ],
              "count": 5,
              "has_more": true,
              "next_cursor": "files-next"
            }
          },
          "conversation_search": {
            "hit_channel_seqs": [101],
            "total": 1,
            "next_cursor": "compat-message-next"
          }
        }
        """.utf8))

        let items = ["messages", "files"].flatMap { response.resultsByType[$0]?.items ?? [] }
        let pagination = TenantConversationSearchPaginationState(response: response, items: items)

        XCTAssertTrue(pagination.hasMore)
        XCTAssertEqual(pagination.typeCursors["messages"], "messages-next")
        XCTAssertEqual(pagination.typeCursors["files"], "files-next")
        XCTAssertNotEqual(pagination.typeCursors["files"], pagination.typeCursors["messages"])
        XCTAssertNil(pagination.genericCursor(for: ["messages", "files"]))
        XCTAssertEqual(pagination.hitChannelSeqs, [101, 205])
        XCTAssertEqual(pagination.total, 6)
    }

    func testConversationSearchPaginationUsesCompatibilityCursorOnlyForMessages() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "合同",
          "scope": "conversation",
          "types": ["messages", "files"],
          "limit": 20,
          "results_by_type": {
            "messages": {
              "items": [],
              "count": 0,
              "has_more": false
            },
            "files": {
              "items": [],
              "count": 3,
              "has_more": true,
              "next_cursor": "files-next"
            }
          },
          "conversation_search": {
            "hit_channel_seqs": [],
            "total": 0,
            "next_cursor": "compat-message-next"
          }
        }
        """.utf8))

        let pagination = TenantConversationSearchPaginationState(response: response, items: [])

        XCTAssertTrue(pagination.hasMore)
        XCTAssertEqual(pagination.typeCursors["messages"], "compat-message-next")
        XCTAssertEqual(pagination.typeCursors["files"], "files-next")
        XCTAssertNil(pagination.genericCursor(for: ["messages", "files"]))
        XCTAssertEqual(pagination.genericCursor(for: ["messages"]), "compat-message-next")
        XCTAssertEqual(pagination.total, 3)
    }

    func testTenantSearchMessageDisplayHidesDuplicateTitleSnippet() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-1",
          "type": "message",
          "title": " 普通消息测试 1782525965 ",
          "snippet": "普通消息测试   1782525965",
          "subtitle": "普通消息测试 1782525965",
          "highlight_ranges": [
            {"field":"snippet","start":0,"length":2}
          ],
          "source": "tenant.messages"
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试   1782525965")
        XCTAssertEqual(display.primaryField, "snippet")
        XCTAssertNil(display.secondaryText)
    }

    func testTenantSearchMessageDisplayKeepsDistinctSubtitle() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-2",
          "type": "message",
          "title": "普通消息测试 1782525965",
          "snippet": "普通消息测试 1782525965",
          "subtitle": "QA 容量临界群 · 昨天 19:03",
          "source": "tenant.messages"
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试 1782525965")
        XCTAssertEqual(display.primaryField, "snippet")
        XCTAssertEqual(display.secondaryText, "QA 容量临界群 · 昨天 19:03")
        XCTAssertEqual(display.secondaryField, "subtitle")
    }

    func testTenantSearchDisplayDoesNotCaseFilterBackendResults() throws {
        let response = try JSONDecoder().decode(RemoteTenantSearchResponse.self, from: Data("""
        {
          "query": "hello",
          "scope": "global",
          "types": ["messages", "files"],
          "results_by_type": {
            "messages": {
              "items": [
                {
                  "result_id": "message:hello-1",
                  "type": "message",
                  "title": "Hello",
                  "snippet": "Hello from backend",
                  "source": "tenant.messages"
                }
              ]
            },
            "files": {
              "items": [
                {
                  "result_id": "file:report-1",
                  "type": "file",
                  "title": "Report-Q2.pdf",
                  "snippet": "REPORT",
                  "source": "tenant.files"
                }
              ]
            }
          },
          "parsed_filters": [
            {"type":"sender","key":"from","operator":"FROM","value":"Alice","raw":"FROM:Alice"}
          ]
        }
        """.utf8))

        let message = try XCTUnwrap(response.resultsByType["messages"]?.items.first)
        let file = try XCTUnwrap(response.resultsByType["files"]?.items.first)
        let filter = try XCTUnwrap(response.parsedFilters.first)

        XCTAssertFalse(message.isBlockedFromChatSearchDisplay)
        XCTAssertFalse(file.isBlockedFromChatSearchDisplay)
        XCTAssertEqual(message.displayModel.primaryText, "Hello from backend")
        XCTAssertEqual(file.displayModel.primaryText, "Report-Q2.pdf")
        XCTAssertEqual(filter.operatorName, "FROM")
        XCTAssertEqual(filter.displayTitle, "from: Alice")
    }

    func testTenantSearchResultGuardBlocksExplicitRiskAndSystemMarkersOnly() throws {
        let blocked = try decodeTenantSearchResult("""
        {
          "result_id": "message:risk-1",
          "type": "message",
          "title": "风控通知",
          "snippet": "系统通知",
          "source": {
            "risk_notice": true,
            "content_type": "system"
          }
        }
        """)
        let ordinary = try decodeTenantSearchResult("""
        {
          "result_id": "message:normal-1",
          "type": "message",
          "title": "风控侧也已收到敏感通知，普通用户好",
          "snippet": "风控侧也已收到敏感通知，普通用户好",
          "source": "tenant.messages"
        }
        """)

        XCTAssertTrue(blocked.isBlockedFromChatSearchDisplay)
        XCTAssertFalse(ordinary.isBlockedFromChatSearchDisplay)
    }

    func testTenantSearchMessageDisplayUsesFriendlySourceLine() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-3",
          "type": "message",
          "title": "普通消息测试",
          "snippet": "普通消息测试",
          "subtitle": "group #28",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-28",
            "channel_type": "group",
            "channel_seq": 28,
            "message_id": "msg-3"
          },
          "source": {
            "conversation_title": "风控复核群",
            "sender_name": "普通用户",
            "display_time": "09:06"
          }
        }
        """)

        let display = item.displayModel

        XCTAssertEqual(display.primaryText, "普通消息测试")
        XCTAssertEqual(display.secondaryText, "风控复核群 · 普通用户 · 09:06")
    }

    func testTenantSearchMessageDisplayFallsBackWithoutRawChannelID() throws {
        let groupItem = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-group",
          "type": "message",
          "title": "群消息",
          "snippet": "群消息",
          "subtitle": "group #28",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-28",
            "channel_type": "group",
            "channel_seq": 28,
            "message_id": "msg-group"
          },
          "source": "group #28"
        }
        """)
        let directItem = try decodeTenantSearchResult("""
        {
          "result_id": "message:msg-direct",
          "type": "message",
          "title": "单聊消息",
          "snippet": "单聊消息",
          "subtitle": "direct #2",
          "jump_target": {
            "kind": "message",
            "channel_id": "direct-2",
            "channel_type": "direct",
            "channel_seq": 2,
            "message_id": "msg-direct"
          },
          "source": "direct #2"
        }
        """)

        XCTAssertEqual(groupItem.displayModel.secondaryText, "群聊")
        XCTAssertEqual(directItem.displayModel.secondaryText, "单聊")
        XCTAssertFalse(groupItem.displayModel.secondaryText?.contains("#") == true)
        XCTAssertFalse(directItem.displayModel.secondaryText?.contains("#") == true)
    }

    func testTenantSearchFileDisplayUsesFriendlySourceLine() throws {
        let item = try decodeTenantSearchResult("""
        {
          "result_id": "file:file-1",
          "type": "file",
          "title": "Report-Q2.pdf",
          "subtitle": "group #94",
          "jump_target": {
            "kind": "file",
            "channel_id": "group-94",
            "channel_type": "group",
            "file_id": "file-1"
          },
          "source": {
            "conversation_title": "产品内测群",
            "uploader_name": "Alice",
            "display_time": "10:20"
          }
        }
        """)

        XCTAssertEqual(item.displayModel.primaryText, "Report-Q2.pdf")
        XCTAssertEqual(item.displayModel.secondaryText, "产品内测群 · Alice · 10:20")
    }

    func testMessageExtraSearchInvalidationDecodesPayloadAndMatchesSearchResult() throws {
        let extra = try JSONDecoder().decode(RemoteMessageExtra.self, from: Data("""
        {
          "tenant_id": "tenant-1",
          "message_id": "msg-1",
          "channel_id": "group-1",
          "channel_type": "group",
          "channel_seq": 42,
          "extra_type": "moderation",
          "payload": {
            "search_invalidation": true,
            "event_type": "delete_for_all",
            "reason": "delete_for_all",
            "tenant_id": "tenant-1",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "message_id": "msg-1",
            "version": 7,
            "updated_at": "2026-06-27T01:02:03Z",
            "invalidation_key": "msg:group-1:42",
            "client_action": "remove"
          }
        }
        """.utf8))
        let result = try JSONDecoder().decode(RemoteTenantSearchResult.self, from: Data("""
        {
          "result_id": "message:msg-1",
          "type": "message",
          "title": "命中的消息",
          "jump_target": {
            "kind": "message",
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": 42,
            "message_id": "msg-1"
          },
          "source": "tenant.messages"
        }
        """.utf8))

        let invalidation = try XCTUnwrap(SearchInvalidationEvent(
            payload: extra.payload,
            fallbackTenantID: extra.tenantID,
            fallbackChannelID: extra.channelID,
            fallbackChannelType: extra.channelType,
            fallbackChannelSeq: extra.channelSeq,
            fallbackMessageID: extra.messageID,
            fallbackUpdatedAt: extra.createdAt
        ))

        XCTAssertEqual(extra.channelSeq, 42)
        XCTAssertEqual(invalidation.tenantID, "tenant-1")
        XCTAssertEqual(invalidation.eventType, "delete_for_all")
        XCTAssertEqual(invalidation.invalidationKey, "msg:group-1:42")
        XCTAssertEqual(invalidation.channelSeq, 42)
        XCTAssertEqual(invalidation.version, 7)
        XCTAssertTrue(result.matchesSearchInvalidation(invalidation))
    }

    func testConversationSyncDecodesRemovedConversationsForSearchInvalidation() throws {
        let sync = try JSONDecoder().decode(RemoteConversationSyncData.self, from: Data("""
        {
          "version": 12,
          "conversations": [],
          "removed_conversations": [
            {
              "tenant_id": "tenant-1",
              "channel_id": "group-1",
              "channel_type": "group",
              "reason": "permission_lost",
              "version": 4,
              "updated_at": "2026-06-27T01:02:03Z"
            }
          ]
        }
        """.utf8))

        let removed = try XCTUnwrap(sync.removedConversations.first)
        let invalidation = SearchInvalidationEvent(removedConversation: removed)

        XCTAssertEqual(sync.version, 12)
        XCTAssertEqual(removed.channelID, "group-1")
        XCTAssertEqual(removed.channelType, "group")
        XCTAssertTrue(invalidation.isConversationRemoval)
        XCTAssertEqual(invalidation.channelID, "group-1")
    }

    private func decodeTenantSearchResult(_ json: String) throws -> RemoteTenantSearchResult {
        try JSONDecoder().decode(RemoteTenantSearchResult.self, from: Data(json.utf8))
    }
}

// WDT_IOS1_SEARCH_HISTORY_20261113_BEGIN
extension RemoteAPIModelsTests {
    @MainActor
    func testRecentSearchCapsDistinctTermsAndSupportsDeleteAndClear() throws {
        let secrets = SearchHistorySecrets()
        let store = TenantSearchHistoryStore(secretStore: secrets)
        let account = try XCTUnwrap(TenantSearchHistoryStore.Account(deployment: "deployment-a", account: "account-a"))
        let scope = try XCTUnwrap(TenantSearchHistoryStore.Scope(account: account, tenant: "tenant-a", imSubject: "im-a"))

        XCTAssertFalse(store.add(" \n ", scope: scope))
        XCTAssertFalse(store.add(String(repeating: "知", count: 65), scope: scope))
        XCTAssertTrue(secrets.items.isEmpty)
        for index in 0...20 {
            XCTAssertTrue(store.add("词\(index)", scope: scope))
        }
        XCTAssertEqual(store.list(scope: scope), (1...20).reversed().map { "词\($0)" })

        XCTAssertTrue(store.add(" 词4\n", scope: scope))
        let reopened = TenantSearchHistoryStore(secretStore: secrets)
        XCTAssertEqual(reopened.list(scope: scope), ["词4"] + (1...20).reversed().filter { $0 != 4 }.map { "词\($0)" })
        XCTAssertTrue(reopened.remove("词4", scope: scope))
        XCTAssertEqual(reopened.list(scope: scope).count, 19)
        XCTAssertFalse(reopened.list(scope: scope).contains("词4"))
        XCTAssertTrue(reopened.clear(scope: scope))
        XCTAssertTrue(reopened.list(scope: scope).isEmpty)
        XCTAssertTrue(secrets.items.isEmpty)
    }

    @MainActor
    func testRecentSearchIsolatesAllIdentityDimensionsAndClearsOnlyRevokedScopes() throws {
        let secrets = SearchHistorySecrets()
        let store = TenantSearchHistoryStore(secretStore: secrets)
        let account = try XCTUnwrap(TenantSearchHistoryStore.Account(deployment: "deployment-a", account: "account-a"))
        let otherAccount = try XCTUnwrap(TenantSearchHistoryStore.Account(deployment: "deployment-a", account: "account-b"))
        let otherDeployment = try XCTUnwrap(TenantSearchHistoryStore.Account(deployment: "deployment-b", account: "account-a"))

        func scope(
            _ account: TenantSearchHistoryStore.Account, _ tenant: String = "tenant-a",
            _ subject: String = "im-a", _ conversation: String? = nil
        ) throws -> TenantSearchHistoryStore.Scope {
            try XCTUnwrap(TenantSearchHistoryStore.Scope(account: account, tenant: tenant, imSubject: subject, conversation: conversation))
        }

        let global = try scope(account)
        let group = try scope(account, "tenant-a", "im-a", "group:1")
        let direct = try scope(account, "tenant-a", "im-a", "direct:1")
        let otherSubject = try scope(account, "tenant-a", "im-b", "group:1")
        let otherTenant = try scope(account, "tenant-b", "im-a", "group:1")
        let otherAccountScope = try scope(otherAccount)
        let otherDeploymentScope = try scope(otherDeployment)
        let scopes = [global, group, direct, otherSubject, otherTenant, otherAccountScope, otherDeploymentScope]
        for (index, scope) in scopes.enumerated() {
            XCTAssertTrue(store.add("keyword-\(index)", scope: scope))
        }
        let reopened = TenantSearchHistoryStore(secretStore: secrets)
        for (index, scope) in scopes.enumerated() {
            XCTAssertEqual(reopened.list(scope: scope), ["keyword-\(index)"])
        }
        XCTAssertEqual(secrets.items.count, 3)
        XCTAssertTrue(secrets.items.keys.allSatisfy { !$0.account.contains("account-a") })

        XCTAssertTrue(reopened.clearConversation("group:1", tenant: "tenant-a", account: account))
        XCTAssertTrue(reopened.list(scope: group).isEmpty)
        XCTAssertTrue(reopened.list(scope: otherSubject).isEmpty)
        XCTAssertEqual(reopened.list(scope: direct), ["keyword-2"])
        XCTAssertEqual(reopened.list(scope: global), ["keyword-0"])
        XCTAssertEqual(reopened.list(scope: otherTenant), ["keyword-4"])

        XCTAssertTrue(reopened.clearTenant("tenant-a", account: account))
        XCTAssertTrue(reopened.list(scope: global).isEmpty)
        XCTAssertTrue(reopened.list(scope: direct).isEmpty)
        XCTAssertEqual(reopened.list(scope: otherTenant), ["keyword-4"])

        XCTAssertTrue(reopened.clearAccount(account))
        XCTAssertTrue(reopened.list(scope: otherTenant).isEmpty)
        XCTAssertEqual(reopened.list(scope: otherAccountScope), ["keyword-5"])
        XCTAssertEqual(reopened.list(scope: otherDeploymentScope), ["keyword-6"])
    }

    @MainActor
    func testRecentSearchRetriesProtectedPurgeAfterRestartWithoutExposingRevokedTerms() throws {
        let name = "search-history-purge-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = SearchHistorySecrets()
        let store = TenantSearchHistoryStore(secretStore: secrets, purgeDefaults: defaults)
        let account = try XCTUnwrap(TenantSearchHistoryStore.Account(deployment: "deployment", account: "account"))
        func scope(_ tenant: String, _ conversation: String? = nil) throws -> TenantSearchHistoryStore.Scope {
            try XCTUnwrap(TenantSearchHistoryStore.Scope(account: account, tenant: tenant, imSubject: "im", conversation: conversation))
        }
        let removedChat = try scope("tenant-a", "direct:1")
        let otherChat = try scope("tenant-a", "direct:2")
        let otherTenant = try scope("tenant-b")
        XCTAssertTrue(store.add("removed chat term", scope: removedChat))
        XCTAssertTrue(store.add("other chat term", scope: otherChat))
        XCTAssertTrue(store.add("other tenant term", scope: otherTenant))

        secrets.isProtectedDataUnavailable = true
        XCTAssertFalse(store.clearConversation("direct:1", tenant: "tenant-a", account: account))
        XCTAssertFalse(store.add("late query", scope: removedChat))
        let reopened = TenantSearchHistoryStore(secretStore: secrets, purgeDefaults: defaults)
        XCTAssertEqual(reopened.list(scope: removedChat), [])
        secrets.isProtectedDataUnavailable = false
        XCTAssertEqual(reopened.list(scope: removedChat), [])
        XCTAssertEqual(reopened.list(scope: otherChat), ["other chat term"])

        secrets.isProtectedDataUnavailable = true
        XCTAssertFalse(reopened.clearTenant("tenant-a", account: account))
        XCTAssertFalse(reopened.add("late query", scope: otherChat))
        secrets.isProtectedDataUnavailable = false
        XCTAssertFalse(store.add("late query after unlock", scope: otherChat))
        XCTAssertEqual(store.list(scope: otherChat), [])
        XCTAssertEqual(store.list(scope: otherTenant), ["other tenant term"])

        secrets.isProtectedDataUnavailable = true
        XCTAssertFalse(store.clearAccount(account))
        XCTAssertFalse(store.add("late query", scope: otherTenant))
        secrets.isProtectedDataUnavailable = false
        let finalStore = TenantSearchHistoryStore(secretStore: secrets, purgeDefaults: defaults)
        XCTAssertEqual(finalStore.list(scope: otherTenant), [])
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertTrue(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
    }
}

final class SearchHistorySecrets: RememberedLoginSecretStoring { // WDT_IOS1_SEARCH_HISTORY_20261113
    struct Item: Hashable {
        let service: String
        let account: String
    }

    private(set) var items: [Item: Data] = [:]
    var isProtectedDataUnavailable = false

    func data(service: String, account: String) -> Data? {
        guard !isProtectedDataUnavailable else { return nil }
        return items[Item(service: service, account: account)]
    }

    func read(service: String, account: String) -> RememberedLoginSecretRead {
        guard !isProtectedDataUnavailable else { return .unavailable }
        return data(service: service, account: account).map(RememberedLoginSecretRead.found) ?? .missing
    }

    func set(_ data: Data, service: String, account: String) -> Bool {
        guard !isProtectedDataUnavailable else { return false }
        items[Item(service: service, account: account)] = data
        return true
    }

    func delete(service: String, account: String) -> Bool {
        guard !isProtectedDataUnavailable else { return false }
        items[Item(service: service, account: account)] = nil
        return true
    }
}
// WDT_IOS1_SEARCH_HISTORY_20261113_END
