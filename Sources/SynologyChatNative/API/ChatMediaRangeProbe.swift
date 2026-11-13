#if DEBUG
import Foundation
import CryptoKit

/// Read-only investigation pinned to two previously verified synthetic attachments.
/// No arbitrary post IDs, imported credential copies, message writes or player URLs.
struct ChatMediaRangeFixture {
    let postID: Int64
    let filename: String
    let caption: String
    let count: Int
    let sha256: String
    static let all: [Self] = [
        .init(postID: 399431958752, filename: "native-audio-preview.wav", caption: "Native audio playback test — Peter.",
              count: 132344, sha256: "4b25b0f388b09dd473d03bf8e395ee8fe19feef83ff4ceaaa770d333ee6a6901"),
        .init(postID: 399431958753, filename: "native-video-preview.mp4", caption: "Native video playback test — Peter.",
              count: 2864, sha256: "11d7ece0728dc8eaecdda97bb7b6cfdbf2177ff2c3a1123517807af98146b309")
    ]
    func validate(_ post: ChatPost) throws {
        guard post.id == postID, post.channel_id == 93, post.creator_id == 10,
              (post.thread_id ?? 0) == 0, post.type == "file", (post.delete_at ?? 0) == 0,
              post.props?.encrypted != true, post.message == caption,
              post.file_props?.name == filename, post.file_props?.size == Int64(count) else {
            throw ChatAPIError.invalidResponse
        }
    }
}

enum ChatMediaRangeProbe {
    static func getRequest(from original: URLRequest, canonicalPath: Bool = true) throws -> URLRequest {
        guard original.httpMethod == "POST", let url = original.url, url.scheme == "https",
              url.path.hasSuffix("/SYNO.Chat.Post.File"), let body = original.httpBody, body.count <= 4096,
              let form = String(data: body, encoding: .utf8),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ChatAPIError.invalidResponse }
        var fields = URLComponents(); fields.percentEncodedQuery = form
        let items = fields.queryItems ?? []
        guard items.count == 4, Set(items.map(\.name)) == ["api", "method", "version", "post_id"],
              items.first(where: { $0.name == "api" })?.value == "SYNO.Chat.Post.File",
              items.first(where: { $0.name == "method" })?.value == "get",
              items.first(where: { $0.name == "version" })?.value == "2",
              let rawID = items.first(where: { $0.name == "post_id" })?.value,
              let id = Int64(rawID), id > 0,
              Set((components.queryItems ?? []).map(\.name)).isDisjoint(with: items.map(\.name)) else {
            throw ChatAPIError.invalidResponse
        }
        if canonicalPath { components.path.removeLast("/SYNO.Chat.Post.File".count) }
        components.queryItems = (components.queryItems ?? []) + items
        guard let resultURL = components.url else { throw ChatAPIError.invalidResponse }
        var result = original
        result.url = resultURL; result.httpMethod = "GET"; result.httpBody = nil
        result.setValue(nil, forHTTPHeaderField: "Content-Type")
        result.setValue(nil, forHTTPHeaderField: "Content-Length")
        return result
    }

    static func run(receipt: URL) async -> Bool {
        var report: [String: Any] = ["scope": "Read-only synthetic media752/753 in verified Peter conversation93, accounts6+10",
                                     "state": "not_started", "requests": [[String: Any]]()]
        do {
            guard !FileManager.default.fileExists(atPath: receipt.path) else {
                print("The range-check receipt already exists. No request repeated."); return false
            }
            try save(report, to: receipt, initial: true)
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let target = try ChatPeterProbeTarget.resolve(username: account.username, users: await api.users(),
                channels: await api.channels(), members: await api.members(channelID: 93))
            report["owner_id"] = target.ownerID; report["peer_id"] = target.peerID
            report["state"] = "verified_own_conversation"
            try save(report, to: receipt)
            var results: [[String: Any]] = []
            for fixture in ChatMediaRangeFixture.all {
                let post = try await api.post(channelID: 93, postID: fixture.postID)
                try fixture.validate(post)
                let full = try await api.documentPreviewData(postID: fixture.postID, maximumBytes: fixture.count)
                guard full.count == fixture.count, digest(full) == fixture.sha256 else { throw ChatAPIError.invalidResponse }
                for mode in ["GET-canonical", "POST", "GET-api-suffix"] {
                    let method = mode == "POST" ? "POST" : "GET"
                    let original = try api.requestForCall(api: "SYNO.Chat.Post.File", method: "get", version: 2,
                                                         parameters: ["post_id": .integer(fixture.postID)])
                    var request = method == "GET" ? try getRequest(from: original, canonicalPath: mode == "GET-canonical") : original
                    request.timeoutInterval = 15
                    for offset in [Int64(0), Int64(fixture.count / 2), Int64(fixture.count - 128)] {
                        let range = try ChatMediaByteRange(offset: offset, length: 1024, total: Int64(fixture.count))
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
                        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
                        var item: [String: Any] = ["post_id": fixture.postID, "filename": fixture.filename,
                            "method": method, "path_mode": mode == "GET-canonical" ? "discovered_cgi" : "api_suffix", "range": range.header, "expected_bytes": range.expectedCount,
                            "full_original_sha256_verified": fixture.sha256]
                        report["active_request"] = item
                        try save(report, to: receipt)
                        do {
                            let bytes = try await ChatMediaRangeRead(range: range, tlsIdentity: api.makeConnectionDelegate().tlsIdentity)
                                .load(request, configuration: configuration)
                            let expected = full.subdata(in: Int(offset)..<(Int(offset) + range.expectedCount))
                            guard bytes == expected else { throw ChatAPIError.invalidResponse }
                            item["status"] = "strict_206_byte_equal"; item["http_status_verified"] = 206
                            item["content_range_verified"] = "bytes \(offset)-\(range.end)/\(fixture.count)"
                            item["sha256"] = digest(bytes)
                        } catch ChatMediaRangeReadError.unsupported {
                            item["status"] = "range_ignored_200_cancelled_before_accumulation"
                            item["http_status_verified"] = 200
                        } catch {
                            item["status"] = "read_stopped"
                            item["error_kind"] = String(describing: type(of: error))
                            results.append(item); report["requests"] = results
                            report.removeValue(forKey: "active_request")
                            try save(report, to: receipt)
                            throw error
                        }
                        results.append(item); report["requests"] = results
                        report.removeValue(forKey: "active_request")
                        try save(report, to: receipt)
                        if item["http_status_verified"] as? Int == 200 { break }
                    }
                }
            }
            report["state"] = "read_only_contract_checked"
            report["no_messages_or_mutations"] = true
            try save(report, to: receipt)
            print("Read-only media range check recorded. No messages or account changes.")
            return true
        } catch {
            report["state"] = "stopped_without_mutation"
            // URLs, credentials and raw network error descriptions stay out of evidence.
            if case ChatAPIError.server(let code) = error { report["api_error_code"] = code }
            else { report["error_kind"] = String(describing: type(of: error)) }
            try? save(report, to: receipt)
            print("Media range check stopped. No messages or account changes; sanitized receipt retained.")
            return false
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func save(_ value: [String: Any], to file: URL, initial: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: file, options: initial ? .withoutOverwriting : .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
