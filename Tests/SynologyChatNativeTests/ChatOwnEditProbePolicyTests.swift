#if DEBUG
import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatOwnEditProbePolicyTests: XCTestCase {
    private func request(api: String = "SYNO.Chat.Post", method: String = "list", version: Int = 5,
                         json: Bool = false, fields: [String: ChatParameter] = ["channel_id": .integer(93), "prev_count": .integer(30), "next_count": .integer(0)]) throws -> URLRequest {
        let client = try ChatAPIClient(session: .init(baseURL: URL(string: "https://probe.invalid")!, sid: "SyntheticSession", synoToken: "SyntheticToken"))
        return try client.makeRequest(api: api, method: method, version: version, path: "entry.cgi", parameters: fields, jsonParameters: json)
    }
    private func create(text: String = "Synthetic café 😀 + &=", json: Bool = false, changes: [String: ChatParameter] = [:]) throws -> URLRequest {
        var fields: [String: ChatParameter] = ["channel_id": .integer(93), "type": .string("normal"), "message": .string(text), "thread_id": .integer(0), "is_thread": .bool(false), "conn_id": .string("")]
        fields.merge(changes, uniquingKeysWith: { _, new in new })
        return try request(method: "create", json: json, fields: fields)
    }
    private func set(id: Int64 = 120, text: String = "Edited café 😀 + &=", json: Bool = false, changes: [String: ChatParameter] = [:]) throws -> URLRequest {
        var fields: [String: ChatParameter] = ["channel_id": .integer(93), "post_id": .integer(id), "thread_id": .integer(0), "message": .string(text)]
        fields.merge(changes, uniquingKeysWith: { _, new in new })
        return try request(method: "set", version: 8, json: json, fields: fields)
    }

    func testExplicitBootstrapReadsAndBoundedOwnConversationLists() throws {
        let policy = ChatOwnEditProbePolicy(role: .model)
        let reads: [(String, String, Int, [String: ChatParameter])] = [
            ("SYNO.API.Info", "query", 1, ["query": .string("all")]),
            ("SYNO.Chat.User", "list", 2, [:]),
            ("SYNO.Chat.Channel", "list", 5, ["is_joined": .bool(true)]),
            ("SYNO.Chat.Channel.Member", "get", 1, ["channel_id": .integer(93)]),
            ("SYNO.Chat.Misc", "acl", 1, [:]),
            ("SYNO.Chat.Admin.Setting", "get", 5, [:]),
            ("SYNO.Chat.User.Preference", "get", 4, [:]),
            ("SYNO.Core.UserSettings", "get", 1, [:]),
            ("SYNO.Core.Desktop.Initdata", "get_user_service", 1, ["launch_app": .string("SYNO.SDS.Chat.Application")]),
            ("SYNO.Core.Region.NTP", "listzone", 1, [:]),
            ("SYNO.Chat.Sticker", "list", 1, [:]),
            ("SYNO.Chat.User.Avatar", "get", 1, ["user_id": .integer(6), "type": .string("S"), "v": .integer(1)])
        ]
        for json in [false, true] {
            for (api, method, version, fields) in reads {
                try policy.check(request(api: api, method: method, version: version, json: json, fields: fields))
            }
            try policy.check(request(json: json))
            try policy.check(request(json: json, fields: ["channel_id": .integer(93), "post_id": .integer(120), "thread_id": .integer(0), "prev_count": .integer(0), "next_count": .integer(0)]))
        }
        XCTAssertEqual(policy.snapshot().rejectedCount, 0)
        XCTAssertEqual(policy.snapshot().apiMethodCounts["SYNO.Chat.Post.list"], 4)
    }

    func testControlCreateIsOnceOnlyAndSupportsActualRawAndJSONForms() throws {
        for json in [false, true] {
            let policy = ChatOwnEditProbePolicy(role: .control)
            try policy.allowCreate(text: "Synthetic café 😀 + &=")
            let value = try create(json: json)
            try policy.check(value)
            // Transport failure cannot rearm or replay an admitted create.
            XCTAssertThrowsError(try policy.check(value))
            XCTAssertThrowsError(try policy.allowCreate(text: "another"))
            XCTAssertEqual(policy.snapshot().createAttempts, 2)
            XCTAssertEqual(policy.snapshot().rejectedCount, 1)
        }
        let model = ChatOwnEditProbePolicy(role: .model)
        XCTAssertThrowsError(try model.allowCreate(text: "Synthetic café 😀 + &="))
        XCTAssertThrowsError(try model.check(create()))
        XCTAssertEqual(model.snapshot().createAttempts, 1)
    }

    func testSetArmsAreExactConsumedAndExplicitlyRearmed() throws {
        for role in [ChatOwnEditProbePolicy.Role.control, .model] {
            let policy = ChatOwnEditProbePolicy(role: role)
            try policy.allowSet(postID: 120, text: "Edited café 😀 + &=")
            XCTAssertThrowsError(try policy.allowSet(postID: 121, text: "overwrite"))
            try policy.check(set(json: true))
            XCTAssertThrowsError(try policy.check(set()))
            try policy.allowSet(postID: 121, text: "Second explicit edit")
            try policy.check(set(id: 121, text: "Second explicit edit"))
            policy.forbidWrites()
            XCTAssertThrowsError(try policy.allowSet(postID: 120, text: "later"))
            XCTAssertThrowsError(try policy.check(set()))
            try policy.check(request())
            XCTAssertEqual(policy.snapshot().setAttempts, 4)
            XCTAssertEqual(policy.snapshot().rejectedCount, 2)
        }
    }

    func testWrongScopeThreadTextAndExtraFieldsDenyAndConsumeArm() throws {
        let changes: [[String: ChatParameter]] = [
            ["channel_id": .integer(94)], ["thread_id": .integer(120)],
            ["post_id": .integer(121)], ["message": .string("different")],
            ["message": .string("Edited cafe\u{301} 😀 + &=")], ["real_delete": .bool(true)]
        ]
        for change in changes {
            let policy = ChatOwnEditProbePolicy(role: .model)
            try policy.allowSet(postID: 120, text: "Edited café 😀 + &=")
            XCTAssertThrowsError(try policy.check(set(changes: change)))
            XCTAssertThrowsError(try policy.check(set()))
            XCTAssertEqual(policy.snapshot().setAttempts, 2)
            XCTAssertEqual(policy.snapshot().rejectedCount, 2)
        }
        for change: [String: ChatParameter] in [["conn_id": .string("live-connection")], ["is_thread": .bool(true)], ["type": .string("file")], ["channel_id": .integer(94)]] {
            let policy = ChatOwnEditProbePolicy(role: .control)
            try policy.allowCreate(text: "Synthetic café 😀 + &=")
            XCTAssertThrowsError(try policy.check(create(changes: change)))
            XCTAssertThrowsError(try policy.check(create()))
            XCTAssertEqual(policy.snapshot().createAttempts, 2)
        }
    }

    func testForeignUnboundedFilteredAndMalformedPostReadsNeverPass() throws {
        let policy = ChatOwnEditProbePolicy(role: .model)
        let changes: [[String: ChatParameter]] = [
            ["channel_id": .integer(94)], ["thread_id": .integer(1)], ["thread_id": .integer(-1)],
            ["prev_count": .integer(31)], ["next_count": .integer(-1)], ["post_id": .integer(0)],
            ["post_id": .string("1.5")], ["file_type": .array([.string("image")])]
        ]
        for change in changes {
            var fields: [String: ChatParameter] = ["channel_id": .integer(93), "prev_count": .integer(30), "next_count": .integer(0)]
            fields.merge(change, uniquingKeysWith: { _, new in new })
            XCTAssertThrowsError(try policy.check(request(fields: fields)))
        }
        XCTAssertThrowsError(try policy.check(request(fields: ["channel_id": .integer(93)])))
        XCTAssertEqual(policy.snapshot().rejectedCount, changes.count + 1)
    }

    func testAllOtherMutationAndUnknownReadMethodsFailClosed() throws {
        let policy = ChatOwnEditProbePolicy(role: .control)
        for (api, method) in [("SYNO.Chat.Post", "delete"), ("SYNO.Chat.Post", "star"), ("SYNO.Chat.Post", "read"), ("SYNO.Chat.User", "set"), ("SYNO.Chat.User.Preference", "set"), ("SYNO.Core.UserSettings", "apply"), ("SYNO.Chat.Channel.Named", "create"), ("SYNO.Chat.Unknown", "get")] {
            XCTAssertThrowsError(try policy.check(request(api: api, method: method, fields: [:])))
        }
        XCTAssertEqual(policy.snapshot().rejectedCount, 8)
        XCTAssertEqual(policy.snapshot().apiMethodCounts, ["other": 8])
        XCTAssertEqual(policy.snapshot().createAttempts, 0)
        XCTAssertEqual(policy.snapshot().setAttempts, 0)
    }

    func testDuplicateKeysBadEscapesStreamsAndTransportShapeReject() throws {
        let valid = try set()
        let policy = ChatOwnEditProbePolicy(role: .model)
        var duplicate = valid
        duplicate.httpBody!.append(Data("&post%5Fid=120".utf8))
        try policy.allowSet(postID: 120, text: "Edited café 😀 + &=")
        XCTAssertThrowsError(try policy.check(duplicate))
        XCTAssertThrowsError(try policy.check(valid))
        XCTAssertEqual(policy.snapshot().setAttempts, 2)
        let malformedAction = ChatOwnEditProbePolicy(role: .control)
        try malformedAction.allowCreate(text: "Synthetic café 😀 + &=")
        var badCreate = try create(); badCreate.httpBody!.append(Data("&bad=%ZZ".utf8))
        XCTAssertThrowsError(try malformedAction.check(badCreate))
        XCTAssertThrowsError(try malformedAction.check(create()))
        XCTAssertEqual(malformedAction.snapshot().createAttempts, 2, "Bad auxiliary fields cannot conceal an attempted write")
        for suffix in ["&bad=%ZZ", "&trailing", "&&", "&=value"] {
            var value = try request(); value.httpBody!.append(Data(suffix.utf8))
            XCTAssertThrowsError(try policy.check(value))
        }
        var value = try request(); value.httpBodyStream = InputStream(data: Data("not-form".utf8))
        XCTAssertThrowsError(try policy.check(value))
        value = try request(); value.httpMethod = "GET"
        XCTAssertThrowsError(try policy.check(value))
        value = try request(); value.setValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
        XCTAssertThrowsError(try policy.check(value))
        value = try request(); value.url = URL(string: "https://probe.invalid/webapi/entry.cgi/SYNO.Chat.Other")!
        XCTAssertThrowsError(try policy.check(value))
        value = try request(); value.url = URL(string: "https://probe.invalid/webapi/entry.cgi/SYNO.Chat.Post?api=SYNO.Chat.Post&method=delete")!
        XCTAssertThrowsError(try policy.check(value))
    }

    func testConcurrentChecksAdmitOneArmedActionAndCountEveryAttempt() throws {
        let policy = ChatOwnEditProbePolicy(role: .control), outcomes = Outcomes()
        try policy.allowCreate(text: "Synthetic café 😀 + &=")
        let value = try create()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do { try policy.check(value); outcomes.accept() } catch { }
        }
        XCTAssertEqual(outcomes.accepted, 1)
        XCTAssertEqual(policy.snapshot().createAttempts, 32)
        XCTAssertEqual(policy.snapshot().rejectedCount, 31)
        XCTAssertEqual(policy.snapshot().apiMethodCounts["SYNO.Chat.Post.create"], 32)
    }

    func testSnapshotsAndErrorsContainOnlyFixedVocabularyAndScalarCounts() throws {
        let policy = ChatOwnEditProbePolicy(role: .model)
        let secret = "SyntheticPrivateBodyAndUsername"
        try policy.allowSet(postID: 120, text: secret)
        do { try policy.check(request(api: secret, method: secret, fields: ["message": .string(secret)])); XCTFail("Unknown route admitted") }
        catch { XCTAssertFalse(error.localizedDescription.contains(secret)); XCTAssertFalse(String(reflecting: error).contains(secret)) }
        XCTAssertThrowsError(try policy.check(set(text: secret + " wrong")))
        let snapshot = String(decoding: try JSONEncoder().encode(policy.snapshot()), as: UTF8.self)
        for forbidden in [secret, "SyntheticSession", "SyntheticToken", "probe.invalid", "http", "post_id", "message"] {
            XCTAssertFalse(snapshot.contains(forbidden))
        }
        XCTAssertEqual(policy.snapshot().apiMethodCounts, ["other": 1, "SYNO.Chat.Post.set": 1])
        policy.forbidWrites()
        XCTAssertThrowsError(try policy.allowCreate(text: secret))
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func accept() { lock.lock(); count += 1; lock.unlock() }
        var accepted: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
#endif
