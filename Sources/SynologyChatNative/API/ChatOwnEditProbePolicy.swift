#if DEBUG
import Foundation

/// A fail-closed transport boundary for the isolated, own-account edit probe.
/// It deliberately contains neither session persistence nor response handling.
final class ChatOwnEditProbePolicy: @unchecked Sendable {
    enum Role: Sendable { case control, model }
    enum Failure: Error, LocalizedError {
        case rejected
        var errorDescription: String? { "The isolated edit probe rejected a request." }
    }
    struct Snapshot: Codable, Sendable {
        let apiMethodCounts: [String: Int]
        let createAttempts: Int
        let setAttempts: Int
        let rejectedCount: Int
    }

    private let role: Role
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var creates = 0, sets = 0, rejected = 0
    private var closed = false, createArmedEver = false
    private var createText: Data?
    private var setArm: (id: Int64, text: Data)?

    init(role: Role) { self.role = role }

    func allowCreate(text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard role == .control, !closed, !createArmedEver else { throw Failure.rejected }
        createArmedEver = true
        createText = Data(text.utf8)
    }

    func allowSet(postID: Int64, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed, postID > 0, setArm == nil else { throw Failure.rejected }
        setArm = (postID, Data(text.utf8))
    }

    func forbidWrites() {
        lock.lock(); defer { lock.unlock() }
        closed = true; createText = nil; setArm = nil
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(apiMethodCounts: counts, createAttempts: creates,
                        setAttempts: sets, rejectedCount: rejected)
    }

    func check(_ request: URLRequest) throws {
        lock.lock(); defer { lock.unlock() }
        // Decode pairs first, retaining duplicates so malformed action attempts
        // still count before denial. No caller-supplied value becomes a log key.
        let parsed = Self.formPairs(request.httpBody)
        let pairs = parsed?.pairs
        let apis = pairs?.filter { $0.0 == "api" }.map { Self.scalar($0.1) } ?? []
        let methods = pairs?.filter { $0.0 == "method" }.map { Self.scalar($0.1) } ?? []
        let create = apis.contains("SYNO.Chat.Post") && methods.contains("create")
        let set = apis.contains("SYNO.Chat.Post") && methods.contains("set")
        if create { creates += 1 }
        if set { sets += 1 }
        let armedCreate = create ? createText : nil
        let armedSet = set ? setArm : nil
        // Any attempted action consumes its arm, including a rejected attempt.
        if create { createText = nil }
        if set { setArm = nil }
        let key: String
        if apis.count == 1, methods.count == 1,
           let api = apis.first, let method = methods.first,
           Self.knownKeys.contains(api + "." + method) { key = api + "." + method }
        else { key = "other" }
        counts[key, default: 0] += 1

        do {
            guard request.httpMethod == "POST", request.httpBodyStream == nil,
                  request.value(forHTTPHeaderField: "Content-Type")?.lowercased() == "application/x-www-form-urlencoded; charset=utf-8",
                  parsed?.valid == true, let pairs, !pairs.isEmpty, Set(pairs.map { $0.0 }).count == pairs.count,
                  apis.count == 1, methods.count == 1 else { throw Failure.rejected }
            let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, Self.scalar($0.1)) })
            guard let api = values["api"], let method = values["method"],
                  let version = values["version"], Int(version).map({ $0 > 0 }) == true,
                  let url = request.url, url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.path.hasSuffix("/webapi/entry.cgi/" + api) || url.path.hasSuffix("/webapi/query.cgi/" + api) else { throw Failure.rejected }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard Set(query.map(\.name)).isSubset(of: ["_sid", "SynoToken"]),
                  Set(query.map(\.name)).count == query.count else { throw Failure.rejected }
            let parameterKeys = Set(values.keys).subtracting(["api", "method", "version"])
            if api == "SYNO.Chat.Post" {
                guard values["channel_id"] == "93" else { throw Failure.rejected }
                if method == "list" {
                    guard version == "5", parameterKeys.isSubset(of: ["channel_id", "post_id", "thread_id", "prev_count", "next_count"]),
                          Self.count(values["prev_count"]), Self.count(values["next_count"]),
                          values["thread_id"] == nil || values["thread_id"] == "0",
                          values["post_id"] == nil || Self.positive(values["post_id"]) != nil else { throw Failure.rejected }
                    return
                }
                guard !closed else { throw Failure.rejected }
                if method == "create" {
                    guard role == .control, version == "5", let armedCreate,
                          parameterKeys == ["channel_id", "type", "message", "is_thread", "thread_id", "conn_id"],
                          values["type"] == "normal", values["is_thread"] == "false", values["thread_id"] == "0",
                          values["conn_id"] == "", let text = values["message"], Data(text.utf8) == armedCreate else { throw Failure.rejected }
                    return
                }
                if method == "set" {
                    guard version == "8", let armedSet,
                          parameterKeys == ["channel_id", "post_id", "thread_id", "message"],
                          Self.positive(values["post_id"]) == armedSet.id, values["thread_id"] == "0",
                          let text = values["message"], Data(text.utf8) == armedSet.text else { throw Failure.rejected }
                    return
                }
                throw Failure.rejected
            }
            guard let rule = Self.reads[api + "." + method], version == rule.version,
                  parameterKeys.isSubset(of: rule.parameters) else { throw Failure.rejected }
            // Bootstrap reads are explicit endpoints, never a wildcard get/list.
            if api == "SYNO.API.Info" { guard values["query"] == "all" else { throw Failure.rejected } }
            if api == "SYNO.Chat.Channel.Member" { guard Self.positive(values["channel_id"]) != nil else { throw Failure.rejected } }
            if api == "SYNO.Chat.Channel" { guard values["is_joined"] == "true" else { throw Failure.rejected } }
            if api == "SYNO.Core.Desktop.Initdata" { guard values["launch_app"] == "SYNO.SDS.Chat.Application" else { throw Failure.rejected } }
            if api == "SYNO.Chat.User.Avatar" {
                guard Self.positive(values["user_id"]) != nil, ["S", "M", "L"].contains(values["type"] ?? ""),
                      let v = values["v"], let number = Int64(v), number >= 0 else { throw Failure.rejected }
            }
        } catch {
            rejected += 1
            throw Failure.rejected
        }
    }

    private struct ReadRule: Sendable { let version: String; let parameters: Set<String> }
    private static let reads: [String: ReadRule] = [
        "SYNO.API.Info.query": .init(version: "1", parameters: ["query"]),
        "SYNO.Chat.User.list": .init(version: "2", parameters: []),
        "SYNO.Chat.Channel.list": .init(version: "5", parameters: ["is_joined"]),
        "SYNO.Chat.Channel.Member.get": .init(version: "1", parameters: ["channel_id"]),
        "SYNO.Chat.Misc.acl": .init(version: "1", parameters: []),
        "SYNO.Chat.Admin.Setting.get": .init(version: "5", parameters: []),
        "SYNO.Chat.User.Preference.get": .init(version: "4", parameters: []),
        "SYNO.Core.UserSettings.get": .init(version: "1", parameters: []),
        "SYNO.Core.Desktop.Initdata.get_user_service": .init(version: "1", parameters: ["launch_app"]),
        "SYNO.Core.Region.NTP.listzone": .init(version: "1", parameters: []),
        "SYNO.Chat.Sticker.list": .init(version: "1", parameters: []),
        "SYNO.Chat.User.Avatar.get": .init(version: "1", parameters: ["user_id", "type", "v"])
    ]
    private static let knownKeys = Set(reads.keys).union(["SYNO.Chat.Post.list", "SYNO.Chat.Post.create", "SYNO.Chat.Post.set"])
    private static func positive(_ value: String?) -> Int64? {
        guard let value, let number = Int64(value), number > 0, String(number) == value else { return nil }
        return number
    }
    private static func count(_ value: String?) -> Bool {
        guard let value, let number = Int(value), (0...30).contains(number), String(number) == value else { return false }
        return true
    }
    private static func scalar(_ value: String) -> String {
        // makeRequest emits either a raw string or a JSON-encoded string.
        // Only JSON strings are unwrapped; objects/arrays never gain authority.
        (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value
    }
    private struct ParsedForm { let pairs: [(String, String)]; let valid: Bool }
    private static func formPairs(_ body: Data?) -> ParsedForm? {
        guard let body, !body.isEmpty, body.count <= 128 * 1024,
              let form = String(data: body, encoding: .utf8) else { return nil }
        var result: [(String, String)] = []
        var valid = true
        for part in form.split(separator: "&", omittingEmptySubsequences: false) {
            let fields = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let key = String(fields[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(fields[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !key.isEmpty else { valid = false; continue }
            result.append((key, value))
        }
        return ParsedForm(pairs: result, valid: valid)
    }
}
#endif
