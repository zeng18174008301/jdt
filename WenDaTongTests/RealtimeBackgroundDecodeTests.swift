import Foundation
import Combine
import XCTest
import IM4Core // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112
import IM4Data // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112
@testable import WenDaTong

// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
extension DomainStoreTests {
    func testRealtimeBackgroundDecodeSerializesRawBatchAndDurableSendAck() async throws {
        let entered = expectation(description: "actual wire decoder held off main")
        let gate = DispatchSemaphore(value: 0)
        let once = DispatchSemaphore(value: 1)
        let codec = RecordingRealtimeWireCodec(passthrough: true) { text, main in
            XCTAssertFalse(main, "actual receive loop invoked wire decode on main")
            if text.contains("hold-first"), once.wait(timeout: .now()) == .success {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
        }
        let f = try await backgroundDecodeFixture(codec: codec)
        defer { gate.signal(); once.signal(); f.close() }
        let local = makeMessage(id: "client-ack", senderId: "actor-a", seq: 0, status: .sending, isOutgoing: true)
        var conversation = makeConversation(id: "decode-channel", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        conversation.messages = [local]
        f.state.conversationStore.commitConversationSnapshots([conversation])
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        _ = try await f.persistence.enqueueOutgoing(ticket: ticket, intent: LocalMessageOutgoingIntent(
            conversation: LocalMessageConversationSnapshot(conversation: conversation, channelID: conversation.id,
                channelType: "group", currentActorID: "actor-a"), message: CachedMessage(message: local),
            operationKind: "send_text", attachment: nil), revision: 1)
        let pendingBefore = try await f.persistence.pendingOutbox(ticket: ticket)
        XCTAssertEqual(pendingBefore.map(\.clientMessageID), ["client-ack"])
        let first = backgroundMessage("hold-first", sequence: 1)
        var ack = backgroundMessage("server-ack", sequence: 2, sender: "actor-a")
        ack["client_msg_no"] = "client-ack"
        let drained = expectation(description: "ordered messages consumed by original AppState")
        var delivered: [String] = []
        let downstream = try XCTUnwrap(f.client.onEnvelope)
        f.client.onEnvelope = { envelope in
            if envelope.type == "decode_barrier" {
                f.state.flushPendingRealtimeMessagesForTesting(); drained.fulfill(); return
            }
            XCTAssertFalse(envelope.decodedMessage?.decodedOnMainThread ?? true)
            delivered.append(envelope.type)
            downstream(envelope)
        }
        f.socket.enqueue(.string(try backgroundWire(type: "message", message: first)))
        let batch: [String: Any] = ["type": "batch", "payload": ["frames": [
            ["type": "batch", "payload": ["frames": [["type": "send_ack", "payload": ["message": ack]]]]],
            ["type": "message_push", "payload": ["message": first]],
            ["type": "pong", "payload": [:]]
        ]]]
        f.socket.enqueue(.data(try JSONSerialization.data(withJSONObject: batch)))
        f.socket.enqueue(.string(backgroundBarrier))
        f.start()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(codec.decodedInputTexts().count, 2, "second frame overtook suspended decode")
        XCTAssertEqual((f.state.conversationStore.conversationMessageSnapshot(id: conversation.id)?.messages ?? []).map(\.id), ["client-ack"])
        gate.signal()
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(delivered, ["message", "send_ack"], "batch order or original dedupe changed")
        let current = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: conversation.id))
        XCTAssertEqual(current.messages.map(\.id), ["hold-first", "server-ack"])
        XCTAssertEqual(current.unread, 1)
        XCTAssertEqual(current.messages.last?.status, .sent)
        XCTAssertEqual(f.state.conversationStore.latestReadableSequence(in: current), 2)
        var pending = try await f.persistence.pendingOutbox(ticket: ticket)
        for _ in 0..<100 where !pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            pending = try await f.persistence.pendingOutbox(ticket: ticket)
        }
        XCTAssertTrue(pending.isEmpty, "original send_ack did not finalize durable outbox")
        let disk = try await f.persistence.activateAndLoad(context: f.state.apiContext,
            sessionGeneration: f.state.localMessageSessionGeneration)
        XCTAssertTrue(disk.conversations.flatMap(\.messages).contains { $0.id == "server-ack" && $0.channelSeq == 2 })
        XCTAssertEqual(sentPacketTypes(f.socket), ["connect"], "decode introduced resend/ACK frames")
        XCTAssertTrue(f.http.requests().filter { $0.url?.path.contains("ack") == true }.isEmpty)
    }

    func testRealtimeBackgroundDecodeRechecksExistingSessionBindingAndKeepsCredentialRefresh() async throws {
        for change in ["tenant", "A-B-A", "reauthentication", "logout-login", "credential-refresh", "auth-revoked", "cancel"] {
            let entered = expectation(description: "held actual frame \(change)")
            let gate = DispatchSemaphore(value: 0)
            let once = DispatchSemaphore(value: 1)
            let codec = RecordingRealtimeWireCodec(passthrough: true) { text, main in
                XCTAssertFalse(main)
                if text.contains("hold-first"), once.wait(timeout: .now()) == .success {
                    entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
                }
            }
            let f = try await backgroundDecodeFixture(codec: codec)
            defer { gate.signal(); once.signal(); f.close() }
            let original = f.state.apiContext
            let ackTicket = try XCTUnwrap(f.state.localMessageTicket)
            if change == "credential-refresh" {
                let local = makeMessage(id: "rotating-client", senderId: "actor-a", seq: 0, status: .sending, isOutgoing: true)
                var conversation = makeConversation(id: "decode-channel", kind: .group, unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
                conversation.messages = [local]
                f.state.conversationStore.commitConversationSnapshots([conversation])
                _ = try await f.persistence.enqueueOutgoing(ticket: ackTicket, intent: LocalMessageOutgoingIntent(
                    conversation: LocalMessageConversationSnapshot(conversation: conversation, channelID: conversation.id,
                        channelType: "group", currentActorID: "actor-a"), message: CachedMessage(message: local),
                    operationKind: "send_text", attachment: nil), revision: 1)
            }
            let initialGeneration = f.state.localMessageSessionGeneration
            let drained: XCTestExpectation? = change == "cancel" ? nil : expectation(description: "binding barrier \(change)")
            var accepted: [String] = []
            var rejections: [RealtimeConnectionDiagnostic.Handling] = []
            let priorDiagnostic = f.client.onDiagnostic
            f.client.onDiagnostic = { event, scope in
                priorDiagnostic?(event, scope)
                if event.handling == .appAuthRejected || event.handling == .appScopeRejected { rejections.append(event.handling) }
                // An unauthenticated business barrier is also correctly rejected; wait on the original diagnostic instead.
                if change == "auth-revoked", event.handling == .appAuthRejected { drained?.fulfill() }
            }
            let downstream = try XCTUnwrap(f.client.onEnvelope)
            f.client.onEnvelope = { envelope in
                if envelope.type == "decode_barrier" { drained?.fulfill(); return }
                accepted.append(envelope.type); downstream(envelope)
            }
            var ack = backgroundMessage("hold-first", sequence: 1, sender: change == "credential-refresh" ? "actor-a" : "peer")
            if change == "credential-refresh" { ack["client_msg_no"] = "rotating-client" }
            let batch: [String: Any] = ["type": "batch", "payload": ["frames": [
                ["type": "pong", "payload": [:]],
                ["type": "send_ack", "payload": ["message": ack]]
            ]]]
            f.socket.enqueue(.data(try JSONSerialization.data(withJSONObject: batch)))
            f.socket.enqueue(.string(backgroundBarrier)); f.start()
            await fulfillment(of: [entered], timeout: 2)
            f.client.awaitingPong = true
            var next = original
            switch change {
            case "tenant": next.tenantID = "other-tenant"; f.state.apiContext = next
            case "A-B-A":
                next.tenantID = "other-tenant"; f.state.apiContext = next; f.state.apiContext = original
            case "reauthentication":
                next.sessionEpoch = UUID().uuidString
                f.state.sessionReauthenticationCommit = (old: original.authSessionFence, new: next.authSessionFence)
                f.state.apiContext = next; f.state.sessionReauthenticationCommit = nil
                XCTAssertEqual(f.state.localMessageSessionGeneration, initialGeneration)
            case "logout-login":
                f.state.setAuthenticated(false); next.sessionEpoch = UUID().uuidString
                f.state.apiContext = next; f.state.setAuthenticated(true)
            case "auth-revoked": f.state.setAuthenticated(false)
            case "credential-refresh":
                next.credentialRevision += 1; next.imToken = "rotated-same-session"
                f.state.apiContext = next
                XCTAssertEqual(f.state.localMessageSessionGeneration, initialGeneration)
            default: break
            }
            let before = f.state.conversationStore.conversationMessageSnapshots()
            let projectionRevision = f.state.localMessageProjectionRevision
            let receive = try XCTUnwrap(f.client.receiveTask)
            if change == "cancel" { receive.cancel() }
            gate.signal()
            if change == "cancel" { await receive.value }
            else {
                await fulfillment(of: [try XCTUnwrap(drained)], timeout: 3)
                XCTAssertFalse(f.client.awaitingPong, "control pong was dropped by App session check")
                if change == "auth-revoked" { XCTAssertEqual(rejections, [.appAuthRejected]) }
                else if change != "credential-refresh" { XCTAssertEqual(rejections, [.appScopeRejected]) }
            }
            if change == "credential-refresh" {
                XCTAssertEqual(accepted, ["send_ack"])
                var pending = try await f.persistence.pendingOutbox(ticket: ackTicket)
                for _ in 0..<100 where !pending.isEmpty {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    pending = try await f.persistence.pendingOutbox(ticket: ackTicket)
                }
                XCTAssertTrue(pending.isEmpty, "same-session rotating-token ACK lost durable completion")
                XCTAssertTrue((f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages ?? []).contains { $0.id == "hold-first" })
            } else {
                XCTAssertEqual(accepted, [], change)
                XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshots(), before, change)
                XCTAssertEqual(f.state.localMessageProjectionRevision, projectionRevision, change)
                let disk = try await f.persistence.activateAndLoad(context: f.state.apiContext,
                    sessionGeneration: f.state.localMessageSessionGeneration)
                XCTAssertFalse(disk.conversations.flatMap(\.messages).contains { $0.id == "hold-first" }, change)
            }
            XCTAssertTrue(f.http.requests().filter { $0.url?.path.contains("ack") == true }.isEmpty, change)
            XCTAssertEqual(sentPacketTypes(f.socket), ["connect"], change)
        }
    }

    func testRealtimeBackgroundDecodeRetiredWorkerCannotBlockOrPublishIntoNewConnection() async throws {
        let entered = expectation(description: "old connection decoder held")
        let gate = DispatchSemaphore(value: 0)
        let codec = RecordingRealtimeWireCodec(passthrough: true) { text, main in
            XCTAssertFalse(main)
            if text.contains("hold-first") { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 5), .success) }
        }
        let old = FakeRealtimeWebSocketTask()
        let fresh = FakeRealtimeWebSocketTask(receiveMessages: [.string(backgroundConnectAck),
            .string(try backgroundWire(type: "send_ack", message: backgroundMessage("fresh", sequence: 1))),
            .string(backgroundBarrier)])
        let f = try await backgroundDecodeFixture(codec: codec, socket: old,
            transport: SequencedRealtimeWebSocketTransport(tasks: [old, fresh]))
        defer { gate.signal(); f.close() }
        let drained = expectation(description: "new worker consumed before old decode released")
        var delivered: [String] = []
        let downstream = try XCTUnwrap(f.client.onEnvelope)
        f.client.onEnvelope = { envelope in
            if envelope.type == "decode_barrier" { drained.fulfill(); return }
            delivered.append(envelope.decodedMessage?.value?.messageID ?? "missing"); downstream(envelope)
        }
        old.enqueue(.string(try backgroundWire(type: "send_ack", message: backgroundMessage("hold-first", sequence: 1))))
        f.start(); await fulfillment(of: [entered], timeout: 2)
        let oldReceive = try XCTUnwrap(f.client.receiveTask)
        let oldGeneration = f.client.connectionGeneration
        f.client.start(url: URL(string: "wss://example.test/im/ws")!, token: "connection-token-rotated")
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertGreaterThan(f.client.connectionGeneration, oldGeneration)
        XCTAssertEqual(delivered, ["fresh"])
        gate.signal(); await oldReceive.value
        XCTAssertEqual(delivered, ["fresh"])
        XCTAssertEqual((f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages ?? []).map(\.id), ["fresh"])
        XCTAssertEqual(old.cancelCount(), 1)
        XCTAssertEqual(fresh.cancelCount(), 0)
        XCTAssertEqual(sentPacketTypes(old), ["connect"])
        XCTAssertEqual(sentPacketTypes(fresh), ["connect"])
    }

    func testRealtimeBackgroundDecodePreservesNestedWireValuesAndMalformedFallback() async throws {
        let codec = RecordingRealtimeWireCodec(passthrough: true) { _, main in XCTAssertFalse(main) }
        let f = try await backgroundDecodeFixture(codec: codec)
        defer { f.close() }
        var message = backgroundMessage("9007199254740993", sequence: Int64.max)
        message["read_count"] = 3; message["is_edited"] = true; message["edit_revision"] = Int64.max
        message["created_at"] = "2026-11-10T01:02:03.456+07:00"
        message["payload"] = ["text": "保留😀", "large": Int64.max, "fraction": 1.25,
            "bool": true, "null": NSNull(), "nested": ["future": [false, "1"]]]
        var rtc = message; rtc["message_id"] = "outer-rtc"; rtc["content_type"] = " RTC_CALL_RECORD "
        let payloads: [[String: Any]] = [["message": message], rtc,
            ["message": NSNull(), "content_type": "rtc_call_record"],
            ["message": ["read_count": "invalid"]], ["message": [String: Any]()]]
        var expected: [RemoteMessage?] = []
        for payload in payloads {
            let wire = try backgroundObject(["type": "message_push", "payload": payload])
            let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data(wire.utf8))
            // Baseline scalar/null invokes a Foundation ObjC exception (separate probe).
            // The private typed-container guard now specifies the normal nil/fallback outcome.
            expected.append(payload["message"] is NSNull ? nil : legacyBackgroundMessage(envelope))
            f.socket.enqueue(.string(wire))
        }
        f.socket.enqueue(.string("{not valid JSON"))
        f.socket.enqueue(.data(Data([0xFF, 0xFE])))
        f.socket.enqueue(.string(String(repeating: "x", count: RealtimeBatchExpander.maximumWireBytes + 1)))
        f.socket.enqueue(.string(try backgroundObject(["type": "future_type", "payload": ["unknown": ["bool": true, "null": NSNull()]]])))
        f.socket.enqueue(.string(backgroundBarrier))
        let drained = expectation(description: "wire semantics barrier")
        var actual: [RemoteMessage?] = []; var unknown = false
        f.client.onEnvelope = { envelope in
            if envelope.type == "decode_barrier" { drained.fulfill(); return }
            if envelope.type == "future_type" {
                unknown = true
                XCTAssertEqual(envelope.payload["unknown"], .object(["bool": .bool(true), "null": .null]))
                XCTAssertNil(envelope.decodedMessage); return
            }
            XCTAssertNotNil(envelope.decodedMessage)
            XCTAssertFalse(envelope.decodedMessage?.decodedOnMainThread ?? true)
            actual.append(f.state.decodeRealtimeMessage(envelope))
        }
        f.start(); await fulfillment(of: [drained], timeout: 3)
        XCTAssertTrue(unknown); XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a?.messageID, e?.messageID); XCTAssertEqual(a?.clientMsgNo, e?.clientMsgNo)
            XCTAssertEqual(a?.channelID, e?.channelID); XCTAssertEqual(a?.channelType, e?.channelType)
            XCTAssertEqual(a?.channelSeq, e?.channelSeq); XCTAssertEqual(a?.payload, e?.payload)
            XCTAssertEqual(a?.createdAt, e?.createdAt); XCTAssertEqual(a?.readCount, e?.readCount)
            XCTAssertEqual(a?.contentType, e?.contentType); XCTAssertEqual(a?.status, e?.status)
            XCTAssertEqual(a?.isEdited, e?.isEdited); XCTAssertEqual(a?.editRevision, e?.editRevision)
            XCTAssertEqual(a?.senderProvenance, e?.senderProvenance)
        }
        let first = try XCTUnwrap(actual[0])
        XCTAssertEqual(first.channelSeq, Int64.max)
        XCTAssertEqual(first.payload["large"], .int(Int.max))
        XCTAssertNil(actual[2]); XCTAssertNil(actual[3]); XCTAssertEqual(actual[4]?.messageID, "")
    }

    func testRealtimeBackgroundDecodeQUICUsesSameWorkerAndOriginalAppConsumer() async throws {
        let connection = FakeRealtimeQUICConnection(receiveLines: [Data(backgroundConnectAck.utf8),
            Data(try backgroundWire(type: "send_ack", message: backgroundMessage("quic-message", sequence: 1)).utf8),
            Data(backgroundBarrier.utf8)])
        let codec = RecordingRealtimeWireCodec(passthrough: true) { _, main in XCTAssertFalse(main) }
        let f = try await backgroundDecodeFixture(codec: codec, quic: connection)
        defer { f.close() }
        let drained = expectation(description: "QUIC original consumer")
        let downstream = try XCTUnwrap(f.client.onEnvelope)
        f.client.onEnvelope = { envelope in
            if envelope.type == "decode_barrier" { drained.fulfill(); return }
            XCTAssertFalse(envelope.decodedMessage?.decodedOnMainThread ?? true); downstream(envelope)
        }
        f.client.start(request: RealtimeConnectionRequest(url: URL(string: "wss://example.test/im/ws")!,
            token: "unit-test-token", quicRequest: discoveryQUICRequest(token: "unit-test-token")))
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(f.socket.resumeCount(), 0)
        XCTAssertEqual((f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages ?? []).map(\.id), ["quic-message"])
        XCTAssertEqual(connection.sentLineStrings().count, 1)
    }

    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
    func testRealtimeSidecarWorkerAppliesOrderedWebSocketAndQUICFrames() async throws {
        for usesQUIC in [false, true] {
            let suite = "realtime-sidecar-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let message: [String: Any] = ["type": "message", "payload": ["message": backgroundMessage("arrived", sequence: 2)]]
            let edit = sidecarEdit(id: "arrived", sequence: 2)
            let receipt = sidecarReceipt(id: "sent")
            // Nested-first on WebSocket. On QUIC, a rejected nested DTO falls back to the flat payload.
            let extraPayload: [String: Any] = usesQUIC
                ? edit.merging(["extra": ["message_id": []]]) { current, _ in current }
                : ["extra": edit, "message_id": "wrong-flat-target"]
            let receiptPayload: [String: Any] = usesQUIC
                ? receipt.merging(["receipt": ["from_uid": []]]) { current, _ in current }
                : ["receipt": receipt, "from_uid": "wrong-flat-sender"]
            let extra: [String: Any] = ["type": "message_extra", "payload": extraPayload]
            let receiptFrame: [String: Any] = ["type": "message_receipt", "payload": receiptPayload]
            let batch = try backgroundObject(["type": "batch", "payload": ["frames": [message, extra, receiptFrame, extra, receiptFrame]]])
            let connection = usesQUIC ? FakeRealtimeQUICConnection(receiveLines:
                [backgroundConnectAck, batch, backgroundBarrier].map { Data($0.utf8) }) : nil
            let codec = RecordingRealtimeWireCodec(passthrough: true) { _, main in XCTAssertFalse(main) }
            let f = try await backgroundDecodeFixture(codec: codec, quic: connection, isolatedDefaults: defaults)
            defer { f.state.remoteSyncEngine.cancelRealtimeRecoveryTasks(); f.close() }
            f.state.conversationStore.hydrateCachedConversations([sidecarConversation()])
            let drained = expectation(description: "original serial consumer drained sidecars QUIC=\(usesQUIC)")
            let downstream = try XCTUnwrap(f.client.onSerialEnvelope)
            var delivered: [String] = []
            f.client.onSerialEnvelope = { envelope, diagnostic, delivery in
                if envelope.type == "decode_barrier" { drained.fulfill(); return }
                delivered.append(envelope.type)
                if envelope.type == "message_extra" {
                    XCTAssertEqual(f.state.realtimeIngestBuffer.count, 1)
                    XCTAssertEqual(envelope.decodedSidecar?.decodedOnMainThread, false)
                    if case let .extra(decoded)? = envelope.decodedSidecar?.value {
                        XCTAssertEqual(decoded?.messageID, "arrived")
                    } else { XCTFail("Missing prepared message extra") }
                } else if envelope.type == "message_receipt" {
                    XCTAssertEqual(envelope.decodedSidecar?.decodedOnMainThread, false)
                    if case let .receipt(decoded)? = envelope.decodedSidecar?.value {
                        XCTAssertEqual(decoded?.fromUID, "actor-a")
                    } else { XCTFail("Missing prepared message receipt") }
                }
                await downstream(envelope, diagnostic, delivery)
                if envelope.type == "message_extra" {
                    let edited = f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages.last
                    XCTAssertEqual(edited?.text, "edited on wire")
                    XCTAssertEqual(edited?.editRevision, 2)
                }
            }
            if usesQUIC {
                f.client.start(request: RealtimeConnectionRequest(url: URL(string: "wss://example.test/im/ws")!,
                    token: "unit-test-token", quicRequest: discoveryQUICRequest(token: "unit-test-token")))
            } else {
                for text in [batch, backgroundBarrier] { f.socket.enqueue(.string(text)) }
                f.start()
            }
            await fulfillment(of: [drained], timeout: 3)
            XCTAssertEqual(delivered, ["message", "message_extra", "message_receipt"])
            let messages = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages)
            XCTAssertEqual(messages.map(\.id), ["sent", "arrived"])
            XCTAssertEqual(messages.map(\.channelSeq), [1, 2])
            let sent = try XCTUnwrap(messages.first)
            XCTAssertTrue(sent.deliveryStateKnown)
            XCTAssertFalse(sent.readStateKnown)
            if let connection {
                XCTAssertEqual(f.socket.resumeCount(), 0)
                XCTAssertEqual(connection.sentLineStrings().count, 1)
            } else {
                XCTAssertEqual(sentPacketTypes(f.socket), ["connect"])
            }
        }
    }

    func testRealtimeSidecarCompletedFailureUsesRecoveryAndKeepsSynchronousInjection() async throws {
        for isExtra in [true, false] {
            let type = isExtra ? "message_extra" : "message_receipt"
            let suite = "realtime-sidecar-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let f = try await backgroundDecodeFixture(codec: JSONWireCodec(), isolatedDefaults: defaults)
            defer { f.state.remoteSyncEngine.cancelRealtimeRecoveryTasks(); f.close() }
            f.state.conversationStore.hydrateCachedConversations([sidecarConversation()])
            let before = f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages
            let valid = try backgroundObject(["type": type, "payload": isExtra
                ? ["extra": sidecarEdit(id: "sent", sequence: 1)] : ["receipt": sidecarReceipt(id: "sent")]])
            let key = isExtra ? "extra" : "receipt"
            let malformed = try backgroundObject(["type": type, "payload": [key: ["message_id": []], "message_id": []]])
            let injected = try XCTUnwrap(RealtimeFrameDecoder.decode(.data(Data(valid.utf8)), using: JSONWireCodec()))
            XCTAssertNil(injected.envelope.decodedSidecar)
            let drained = expectation(description: "serial recovery and synchronous injection \(type)")
            let downstream = try XCTUnwrap(f.client.onSerialEnvelope)
            f.client.onSerialEnvelope = { envelope, diagnostic, delivery in
                if envelope.type == "decode_barrier" { drained.fulfill(); return }
                guard envelope.type == type else { XCTFail(envelope.type); return }
                let prepared = envelope.decodedSidecar
                XCTAssertEqual(prepared?.decodedOnMainThread, false)
                switch prepared?.value {
                case .extra(let value)?: XCTAssertTrue(isExtra); XCTAssertNil(value)
                case .receipt(let value)?: XCTAssertFalse(isExtra); XCTAssertNil(value)
                case nil: XCTFail("Malformed sidecar never attempted on worker")
                }
                await downstream(envelope, diagnostic, delivery)
                XCTAssertTrue(f.state.remoteSyncEngine.hasRealtimeRecoveryTask(.refresh))
                XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages, before)
                // A prepared failure is authoritative even if the raw body could decode successfully.
                var preparedFailure = injected.envelope
                preparedFailure.decodedSidecar = prepared
                await downstream(preparedFailure, nil, delivery)
                XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages, before)
            }
            f.socket.enqueue(.string(malformed))
            f.socket.enqueue(.string(backgroundBarrier))
            f.start()
            await fulfillment(of: [drained], timeout: 3)
            f.client.handle(Data(valid.utf8), generation: f.client.connectionGeneration, legID: f.client.activeLegID)
            let after = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel")?.messages.first)
            if isExtra {
                XCTAssertEqual(after.text, "edited on wire")
                XCTAssertEqual(after.editRevision, 2)
            } else {
                XCTAssertTrue(after.deliveryStateKnown)
            }
        }
    }

    func testRealtimeSidecarWorkerRejectsBatchFromRetiredSessionBinding() async throws {
        let entered = expectation(description: "worker holds old sidecar batch")
        let release = DispatchSemaphore(value: 0)
        let codec = RecordingRealtimeWireCodec(passthrough: true) { text, main in
            XCTAssertFalse(main)
            if text.contains("held-sidecars") {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
        }
        let suite = "realtime-sidecar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await backgroundDecodeFixture(codec: codec, isolatedDefaults: defaults)
        defer { release.signal(); f.state.remoteSyncEngine.cancelRealtimeRecoveryTasks(); f.close() }
        f.state.conversationStore.hydrateCachedConversations([sidecarConversation()])
        let original = f.state.apiContext
        let drained = expectation(description: "new binding reached receive barrier")
        var scopeRejections = 0
        let captureAdmission = try XCTUnwrap(f.client.captureIncomingAdmission)
        f.client.captureIncomingAdmission = {
            let check = captureAdmission()
            return {
                let result = check()
                if result == .appScopeRejected { scopeRejections += 1 }
                return result
            }
        }
        let downstream = try XCTUnwrap(f.client.onSerialEnvelope)
        f.client.onSerialEnvelope = { envelope, diagnostic, delivery in
            if envelope.type == "decode_barrier" { drained.fulfill(); return }
            XCTFail("Old \(envelope.type) reached serial application")
            await downstream(envelope, diagnostic, delivery)
        }
        let frames: [[String: Any]] = [
            ["type": "message_extra", "payload": ["extra": sidecarEdit(id: "sent", sequence: 1)]],
            ["type": "message_receipt", "payload": ["receipt": sidecarReceipt(id: "sent")]],
        ]
        f.socket.enqueue(.string(try backgroundObject(["type": "batch", "request_id": "held-sidecars", "payload": ["frames": frames]])))
        f.socket.enqueue(.string(backgroundBarrier))
        f.start()
        await fulfillment(of: [entered], timeout: 2)
        var next = original
        next.sessionEpoch = UUID().uuidString
        f.state.sessionReauthenticationCommit = (old: original.authSessionFence, new: next.authSessionFence)
        f.state.apiContext = next
        f.state.sessionReauthenticationCommit = nil
        let before = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel"))
        let revision = f.state.conversationStore.memorySnapshot.revision
        let persistenceRevision = f.state.localMessageProjectionRevision
        release.signal()
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(scopeRejections, 2)
        XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: "decode-channel"), before)
        XCTAssertEqual(f.state.conversationStore.memorySnapshot.revision, revision)
        XCTAssertEqual(f.state.localMessageProjectionRevision, persistenceRevision)
        XCTAssertFalse(f.state.remoteSyncEngine.hasRealtimeRecoveryTask(.refresh))
    }

    private func sidecarConversation() -> ConversationMessageSnapshot {
        var row = makeConversation(id: "decode-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var sent = makeMessage(id: "sent", senderId: "actor-a", seq: 1, isOutgoing: true, text: "original")
        sent.contentType = "text"
        sent.deliveryStateKnown = false
        sent.readStateKnown = false
        row.messages = [sent]
        row.messageCoveredThroughSeq = 1
        return row
    }

    private func sidecarEdit(id: String, sequence: Int64) -> [String: Any] {
        ["message_id": id, "channel_id": "decode-channel", "channel_type": "group", "channel_seq": sequence,
         "version": 2, "operator_uid": "peer", "extra_type": "edit",
         "payload": ["edit_revision": 2, "payload": ["text": "edited on wire", "edit_revision": 2]]]
    }

    private func sidecarReceipt(id: String) -> [String: Any] {
        ["message_id": id, "channel_id": "decode-channel", "channel_type": "group", "channel_seq": 1,
         "from_uid": "actor-a", "receipt_type": "delivered", "im_uid": "peer", "device_id": "receipt-device"]
    }
    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110: reuse owned actual-wire fixture.
    func backgroundDecodeFixture(codec: any WireCodec, socket: FakeRealtimeWebSocketTask = FakeRealtimeWebSocketTask(),
        transport: (any RealtimeWebSocketTransporting)? = nil, quic: FakeRealtimeQUICConnection? = nil,
        isolatedDefaults: UserDefaults? = nil) async throws -> BackgroundDecodeFixture { // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-decode-" + UUID().uuidString)
        let persistence = MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches"))
        let http = FakeHTTPTransport(results: [])
        // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
        var context = makeAuthenticatedAPIContext(); context.accountID = UUID().uuidString
        context.tenantID = "decode-" + UUID().uuidString; context.imUID = "actor-a"; context.deviceID = UUID().uuidString
        let defaults = isolatedDefaults ?? .standard
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: isolatedDefaults == nil ? nil : [], httpTransport: http,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            startupContext: isolatedDefaults == nil ? nil : context)
        let client = RealtimeClient(transport: transport ?? FakeRealtimeWebSocketTransport(socket: socket),
            quicTransport: FakeRealtimeQUICTransport(result: .success(quic ?? FakeRealtimeQUICConnection())),
            quicConfiguration: RealtimeQUICConfiguration(isEnabled: quic != nil), wireCodec: codec,
            heartbeatIntervalNanoseconds: 100_000_000_000, requestIDProvider: { _ in "decode-connect" },
            networkMonitorFactory: nil, continuity: IMRuntimeWebSocketContinuity())
        let discovery = isolatedDefaults.map { _ in AccessDiscoveryStore(baseDirectory: root.appendingPathComponent("discovery")) }
            ?? AccessDiscoveryStore()
        let state = AppState(api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            accessDiscovery: AccessDiscoveryManager(store: discovery), realtimeClient: client, voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshot")),
            messagePersistence: persistence, biometricDefaults: defaults,
            rememberedLoginCredentialStore: isolatedDefaults == nil
                ? KeychainRememberedLoginCredentialStore() : RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: isolatedDefaults == nil ? IMKeychainSessionStore() : InMemoryProtectedSessionStore(),
            registrationSessionStore: isolatedDefaults == nil
                ? IMKeychainSessionStore(registrationRecovery: true) : InMemoryProtectedSessionStore(), apiContextOverride: context)
        if isolatedDefaults == nil { state.setAuthenticated(true) }
        else { state.authenticationPresentationStore.setInitialAuthentication(true) }
        state.storeCancellables.removeAll()
        // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END
        state.suppressCurrentUserIdentityPersistence = true; state.setCurrentUser(makeUser(id: "actor-a"))
        state.localMessageTicket = try await persistence.ensureTicket(context: context, sessionGeneration: state.localMessageSessionGeneration)
        client.onConnected = nil
        socket.enqueue(.string(backgroundConnectAck))
        return BackgroundDecodeFixture(root: root, socket: socket, client: client, state: state, http: http, persistence: persistence)
    }

    private var backgroundConnectAck: String { #"{"type":"connect_ack","request_id":"decode-connect","payload":{}}"# }
    private var backgroundBarrier: String { #"{"type":"decode_barrier","payload":{}}"# }
    private func backgroundMessage(_ id: String, sequence: Int64, sender: String = "peer") -> [String: Any] {
        ["message_id": id, "channel_id": "decode-channel", "channel_type": "group", "channel_seq": sequence,
         "from_uid": sender, "content_type": "text", "created_at": "2026-11-10T01:00:00Z", "payload": ["text": id]]
    }
    private func backgroundObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func backgroundWire(type: String, message: [String: Any]) throws -> String {
        try backgroundObject(["type": type, "payload": ["message": message]])
    }
    private func legacyBackgroundMessage(_ envelope: RealtimeEnvelope) -> RemoteMessage? {
        let decoder = JSONDecoder()
        if let value = envelope.payload["message"],
           let data = try? JSONSerialization.data(withJSONObject: value.anyValue),
           let message = try? decoder.decode(RemoteMessage.self, from: data) { return message }
        guard envelope.payload["message"] == nil,
              let data = try? JSONSerialization.data(withJSONObject: envelope.payload.mapValues(\.anyValue)),
              let message = try? decoder.decode(RemoteMessage.self, from: data),
              message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" else { return nil }
        return message
    }
}

@MainActor
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110: shared actual-wire fixture.
struct BackgroundDecodeFixture {
    let root: URL
    let socket: FakeRealtimeWebSocketTask
    let client: RealtimeClient
    let state: AppState
    let http: FakeHTTPTransport
    let persistence: MessagePersistenceCoordinator
    func start() { client.start(url: URL(string: "wss://example.test/im/ws")!, token: "unit-test-token") }
    func close() {
        client.disconnect(shouldReconnect: false); client.onEnvelope = nil; state.setAuthenticated(false)
        state.clearPendingRealtimeMessages(reason: "test_close")
        // Keep this owned test directory until SQLite releases its open handles.
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

// WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
final class Phase6RecoveryMappingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var acceptsClaim = true

    func claim(onEntry: () -> Void) -> Bool {
        lock.withLock {
            guard acceptsClaim else { return false }
            acceptsClaim = false
            onEntry()
            return true
        }
    }

    func close() { lock.withLock { acceptsClaim = false } }
    func wait() -> DispatchTimeoutResult { releaseGate.wait(timeout: .now() + 8) }
    func release() {
        close()
        releaseGate.signal()
    }
}

@MainActor
final class Phase6RecoveryFixtureLifetime {
    let gate = Phase6RecoveryMappingGate()
    private let fixture: BackgroundDecodeFixture
    private let http: Phase6RecoveryHTTPTransport
    private let resetProtocol: () -> Void
    private var jobs: [(claim: ConversationStore.HistorySyncClaim, task: Task<Void, Never>)] = []
    private var retries: [Task<Void, Never>] = []
    private var sidecars: [Task<Void, Never>] = []
    private var retired = false
    private var drained = false

    init(fixture: BackgroundDecodeFixture, http: Phase6RecoveryHTTPTransport, resetProtocol: @escaping () -> Void) {
        self.fixture = fixture
        self.http = http
        self.resetProtocol = resetProtocol
        fixture.state.realtimeComputeRuntime.onSequenceRecoveryTask = { [weak self] claim, task in
            self?.jobs.append((claim, task))
        }
    }

    var hasTrackedRecovery: Bool { !jobs.isEmpty }

    func suspendFirstMapping(_ entered: XCTestExpectation) {
        let gate = self.gate
        fixture.state.realtimeComputeRuntime.probe = { phase in
            if case .mapping = phase, gate.claim(onEntry: {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
            }) {
                XCTAssertEqual(gate.wait(), .success)
            }
        }
    }

    // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_BEGIN
    func retire() {
        guard !retired else { return }
        retired = true
        http.closeAdmission()
        gate.close()
        let state = fixture.state
        state.realtimeComputeRuntime.probe = nil
        state.realtimeComputeRuntime.onComputed = nil
        state.realtimeComputeRuntime.onDerivation = nil
        state.realtimeComputeRuntime.onSequenceRecoveryTask = nil
        fixture.close()
        state.remoteSyncEngine.reset()
        state.localMessageSessionGeneration &+= 1
        for row in state.conversationStore.conversationMessageSnapshots() {
            state.beginGroupHistoryBoundaryRequest(context: state.apiContext,
                channelID: state.remoteChannelID(for: row), channelType: state.apiChannelType(for: row.kind))
        }
        for job in jobs {
            state.conversationStore.finishHistorySync(job.claim)
            job.task.cancel()
        }
        retries = Array(state.messageSequenceRecoveryRetryTasks.values)
        state.messageSequenceRecoveryRetryTasks.removeAll()
        for retry in retries { retry.cancel() }
        sidecars = Array(state.deliveryAckTasksByScope.values)
            + [state.deliveryAckSweepTask, state.certificationProfileRefreshTask, state.avatarAuthorityRefreshTask].compactMap { $0 }
        for task in sidecars { task.cancel() }
        state.purgeCertificationIdentityRoot(rebindCurrentScope: false)
        state.purgeAvatarRealtimeProjection(rebindCurrentScope: false)
    }

    func drain() async {
        retire()
        guard !drained else { return }
        gate.release()
        // A recovery Task owns the worker await and the history-claim defer.
        for job in jobs { await job.task.value }
        for retry in retries { await retry.value }
        for task in sidecars { await task.value }
        await http.drain()
        sidecars.removeAll()
        fixture.state.realtimeComputeRuntime.onDerivation = nil
        jobs.removeAll()
        retries.removeAll()
        resetProtocol()
        drained = true
    }

    func verifyHeldPageRetirement(conversationID: String, historyKey: String,
        ticket: LocalMessageSessionTicket, initialFloor: Int64) async throws {
        let state = fixture.state
        let store = state.conversationStore
        let original = try XCTUnwrap(store.conversationMessageSnapshot(id: conversationID))
        XCTAssertEqual(original.messages.map(\.id), ["base"])
        XCTAssertTrue(original.messages.allSatisfy(\.canViewReadDetails))
        var redacted = original
        for index in redacted.messages.indices {
            redacted.messages[index].canViewReadDetails = false
        }
        let originalRevision = store.memorySnapshot.revision
        let queued = Task { try await http.data(for: URLRequest(url: URL(string: "https://platform.example.test/api/platform/apps/current-policy")!)) }
        retire()
        let retiredRevision = store.memorySnapshot.revision
        XCTAssertGreaterThan(retiredRevision, originalRevision)
        XCTAssertEqual(store.conversationMessageSnapshot(id: conversationID), redacted)
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: historyKey))
        var rejected = false
        state.realtimeComputeRuntime.onDerivation = { samples in
            rejected = samples.contains { $0.phase == .rejected }
            XCTAssertFalse(samples.contains { $0.phase == .commit || $0.phase == .storeInstalled })
        }
        do {
            _ = try await queued.value
            XCTFail("a queued HTTP producer must observe closed fixture admission")
        } catch is CancellationError {}
        await drain()
        XCTAssertTrue(rejected)
        let lateGate = Phase6RecoveryMappingGate()
        let lateClaim = { lateGate.claim { XCTFail("a copied probe cannot enter a retired fixture") } }
        lateGate.release()
        XCTAssertFalse(lateClaim())
        XCTAssertFalse(store.isMessageSyncInFlight(historyKey: historyKey))
        XCTAssertEqual(store.memorySnapshot.revision, retiredRevision)
        XCTAssertEqual(store.conversationMessageSnapshot(id: conversationID), redacted)
        let finalFloor = try await fixture.persistence.projectionRevisionFloor(ticket: ticket)
        XCTAssertEqual(finalFloor, initialFloor)
    }
    // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_END
}
// WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END

// WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_BEGIN
final class Phase6RecoveryHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let native: URLSessionHTTPTransport
    private let lock = NSLock()
    private let active = DispatchGroup()
    private var accepting = true

    init(session: URLSession) {
        self.session = session
        native = URLSessionHTTPTransport(session: session)
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        try await perform { try await native.data(for: request) }
    }

    func data(for request: URLRequest, rejectingCrossOriginRedirectsFrom origin: URL) async throws -> HTTPTransportResult {
        try await perform { try await native.data(for: request, rejectingCrossOriginRedirectsFrom: origin) }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }

    private func perform(_ operation: () async throws -> HTTPTransportResult) async throws -> HTTPTransportResult {
        // Close and group entry share the lock. Admission covers the entire native operation.
        try lock.withLock {
            guard accepting else { throw CancellationError() }
            active.enter()
        }
        defer { active.leave() }
        return try await operation()
    }

    func closeAdmission() {
        lock.withLock { accepting = false }
    }

    func drain() async {
        closeAdmission()
        await withCheckedContinuation { continuation in
            active.notify(queue: .global()) { continuation.resume() }
        }
        session.invalidateAndCancel()
    }
}
// WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_END
