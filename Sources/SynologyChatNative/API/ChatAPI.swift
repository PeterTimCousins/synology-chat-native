import Foundation
import ImageIO

/// Contracts recovered from the server's synochat-common.js, validated with read-only requests.
struct ChatSession: Codable {
    let baseURL: URL
    let sid: String
    let synoToken: String
    let tlsServerName: String?
    init(baseURL: URL, sid: String, synoToken: String, tlsServerName: String? = nil) {
        self.baseURL = baseURL; self.sid = sid; self.synoToken = synoToken; self.tlsServerName = tlsServerName
    }
    var tlsIdentity: ChatTLSIdentity? { tlsServerName.flatMap { ChatTLSIdentity(origin: baseURL, serverName: $0) } }
    var hasValidTLSIdentity: Bool { tlsServerName == nil || tlsIdentity != nil }
}

struct ChatAPIEndpoint: Decodable {
    let path: String
    let minVersion: Int
    let maxVersion: Int
    let requestFormat: String?
}

enum ChatParameter: Encodable {
    case integer(Int64), number(Double), string(String), bool(Bool), array([ChatParameter]), object([String:ChatParameter]), null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum ChatAPIError: LocalizedError {
    case invalidServer, unsupportedAPI, invalidResponse, server(Int), http(Int), connection

    var errorDescription: String? { message() }

    func message(language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil)->String {
        func text(_ key:String)->String {
            NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
        func integer(_ key:String,_ code:Int)->String {
            NativeLocalizedStrings.integer(key,Int64(code),language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
        switch self {
        case .invalidServer: return text("Use a direct HTTPS server address for the native preview.")
        case .unsupportedAPI: return text("This server does not support the required Chat API version.")
        case .invalidResponse: return text("The server returned an unexpected response.")
        case .server(let code) where [105, 106, 107, 119].contains(code):
            return integer("The sign-in session was rejected (%lld). Sign in to Synology Chat again and reconnect.",code)
        case .server(117): return text("The server could not complete this request. Wait a moment and try again.")
        case .server(407): return text("One of the fields was not accepted. Check its format and length.")
        case .server(411): return text("Messages are being sent too quickly. Wait a moment before sending again.")
        case .server(let code): return integer("Synology Chat returned error %lld.",code)
        case .http(let code): return integer("The server returned HTTP %lld.",code)
        case .connection: return text("Could not connect securely. Check the server connection and try again.")
        }
    }
}

private struct APIEnvelope<T: Decodable>: Decodable {
    struct Failure: Decodable { let code: Int }
    let success: Bool
    let data: T?
    let error: Failure?
}

/// Never forward session-bearing requests through redirects. Resolve the real server first.
class NoChatRedirects: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let tlsIdentity: ChatTLSIdentity?
    let onUploadProgress: ChatUploadProgressCallback?
    let onDownloadProgress: ChatDownloadProgressCallback?
    init(tlsIdentity: ChatTLSIdentity? = nil, onUploadProgress: ChatUploadProgressCallback? = nil, onDownloadProgress: ChatDownloadProgressCallback? = nil) {
        self.tlsIdentity = tlsIdentity; self.onUploadProgress = onUploadProgress; self.onDownloadProgress = onDownloadProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { onDownloadProgress?(totalBytesWritten, totalBytesExpectedToWrite) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onUploadProgress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let identity = tlsIdentity else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = space.serverTrust, identity.evaluate(trust, host: space.host, port: space.port) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class ChatAPIClient {
    private let credentials: ChatSession
    let network: URLSession
    let makeAttachmentNetwork: (() -> URLSession)?
    private var endpoints: [String: ChatAPIEndpoint] = [:]
#if DEBUG
    /// Isolated acceptance probes may reject/count an authenticated request
    /// before transport. Never log the URL or body; normal clients leave nil.
    var debugRequestGuard: ((URLRequest) throws -> Void)?
#endif

    init(session: ChatSession, network: URLSession? = nil, makeAttachmentNetwork: (() -> URLSession)? = nil) throws {
        guard session.baseURL.scheme == "https", session.baseURL.host != nil,
              session.baseURL.user == nil, session.baseURL.password == nil,
              !session.sid.isEmpty, !session.synoToken.isEmpty, session.hasValidTLSIdentity else {
            throw ChatAPIError.invalidServer
        }
        credentials = session
        self.makeAttachmentNetwork = makeAttachmentNetwork
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.network = network ?? URLSession(configuration: configuration, delegate: NoChatRedirects(tlsIdentity: session.tlsIdentity), delegateQueue: nil)
    }

    func makeConnectionDelegate(onUploadProgress: ChatUploadProgressCallback? = nil, onDownloadProgress: ChatDownloadProgressCallback? = nil) -> NoChatRedirects {
        NoChatRedirects(tlsIdentity: credentials.tlsIdentity, onUploadProgress: onUploadProgress, onDownloadProgress: onDownloadProgress)
    }

    deinit { network.invalidateAndCancel() }

    func discover() async throws {
        let request = try makeRequest(api: "SYNO.API.Info", method: "query", version: 1,
                                      path: "query.cgi", parameters: ["query": .string("all")],
                                      jsonParameters: false, authenticated: false)
        endpoints = try await perform(request)
    }

    func channels() async throws -> [ChatChannel] {
        let data: ChannelList = try await call(api: "SYNO.Chat.Channel", method: "list", version: 5,
                                              parameters: ["is_joined": .bool(true)])
        return data.channels
    }

    func blockChatbot(userID: Int64) async throws {
        guard userID > 1 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Channel.Chatbot", method: "block", version: 1, parameters: ["user_id": .integer(userID)])
    }
    func setWebhookDetails(id: Int64, kind: ChatWebhookKind, draft: ChatWebhookDraft) async throws {
        guard id > 1 else { throw ChatAPIError.invalidResponse }
        var fields: [String: ChatParameter] = ["user_id": .integer(id), "channel_id": .integer(draft.channelID)]
        if kind == .outgoing { fields["url"] = .string(draft.callbackURL); fields["trigger_word"] = .string(draft.normalized.triggerWord) }
        try await callVoid(api: kind.api, method: "set", version: 1, parameters: fields)
    }
    func setWebhookName(id: Int64, name: String) async throws {
        guard id > 1, !name.isEmpty, name.utf16.count <= 32 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Bot", method: "set", version: 1, parameters: ["user_id": .integer(id), "nickname": .string(name)])
    }
    func setWebhookEnabled(id: Int64, enabled: Bool) async throws {
        guard id > 1 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Bot", method: enabled ? "enable" : "disable", version: 1, parameters: ["user_id": .integer(id)])
    }
    func rotateWebhookToken(id: Int64) async throws -> ChatWebhookSecret {
        struct Token: Decodable { let token: String }
        guard id > 1 else { throw ChatAPIError.invalidResponse }
        let value: Token = try await call(api: "SYNO.Chat.Bot", method: "regen_token", version: 1, parameters: ["user_id": .integer(id)])
        guard !value.token.isEmpty else { throw ChatAPIError.invalidResponse }; return .init(value.token)
    }
    func removeWebhook(id: Int64) async throws {
        guard id > 1 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Bot", method: "delete", version: 1, parameters: ["user_id": .integer(id), "real_delete": .bool(false)])
    }
    func incomingWebhookURL(token: ChatWebhookSecret) throws -> URL {
        guard let endpoint = endpoints["SYNO.Chat.External"], endpoint.minVersion <= 2, endpoint.maxVersion >= 2 else { throw ChatAPIError.unsupportedAPI }
        let request = try makeRequest(api: "SYNO.Chat.External", method: "incoming", version: 2, path: endpoint.path,
                                      parameters: ["token": .string(token.reveal())], jsonParameters: endpoint.requestFormat == "JSON", authenticated: false)
        guard let url = request.url, let data = request.httpBody, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.hasSuffix("/SYNO.Chat.External") else { throw ChatAPIError.invalidResponse }
        parts.path.removeLast("/SYNO.Chat.External".count)
        parts.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        guard let result = parts.url else { throw ChatAPIError.invalidResponse }; return result
    }
    func triggerBotAttachment(postID: Int64, selection: ChatBotActionSelection) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Post.Attachment", method: "trigger", version: 1,
                           parameters: ["post_id": .integer(postID), "payload": try selection.payload()])
    }
    func promoteConversation(channelID: Int64, name: String, purpose: String) async throws {
        guard channelID > 2 else { throw ChatAPIError.invalidResponse }
        let draft = ChatChannelPromotionDraft(name: name, purpose: purpose).normalized
        try draft.validate()
        try await callVoid(api: "SYNO.Chat.Channel.Anonymous", method: "promote", version: 2,
                           parameters: ["channel_id": .integer(channelID), "name": .string(draft.name), "purpose": .string(draft.purpose), "message_stay": .string("false")])
    }
    func setNamedChannelDetails(channelID:Int64,patch:ChatChannelDetailsPatch,administratorVerified:Bool = false) async throws {
        guard channelID > 0,(channelID > 2 || administratorVerified),!patch.isEmpty else { throw ChatAPIError.invalidResponse };try patch.validate()
        var parameters:[String:ChatParameter] = ["channel_id":.integer(channelID)]
        if let name = patch.name { parameters["name"] = .string(name) }
        if let purpose = patch.purpose { parameters["purpose"] = .string(purpose) }
        try await callVoid(api:"SYNO.Chat.Channel.Named",method:"set",version:1,parameters:parameters)
    }
    func unjoinedChannels() async throws -> [ChatChannel] {
        let data:ChannelList = try await call(api:"SYNO.Chat.Channel",method:"list",version:5,parameters:["is_joined":.bool(false)])
        guard Set(data.channels.map(\.id)).count == data.channels.count,data.channels.allSatisfy({ $0.id > 0 && $0.is_joined == false }) else { throw ChatAPIError.invalidResponse }
        return data.channels
    }
    func joinPublicChannel(_ channel:ChatChannel) async throws {
        guard channel.canJoinUnencryptedPublic else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel.Named",method:"join",version:1,parameters:["channel_id":.integer(channel.id),"channel_key_enc":.string("")])
    }
    func disjoinNamedChannel(_ channel:ChatChannel) async throws {
        guard channel.canLeaveNamed else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel.Named",method:"disjoin",version:1,parameters:["channel_id":.integer(channel.id)])
    }
    func users() async throws -> [ChatUser] {
        let data: UserList = try await call(api: "SYNO.Chat.User", method: "list", version: 2)
        return data.users
    }

    func channelPermissions() async throws -> ChatChannelPermissions {
        try await call(api: "SYNO.Chat.Misc", method: "acl", version: 1)
    }

    func guestPolicy() async throws -> ChatGuestPolicy {
        try await call(api: "SYNO.Chat.Admin.Setting", method: "get", version: 5)
    }

    func applyGuestAction(_ record: ChatGuestActionRecord) async throws {
        try record.validate()
        try await callVoid(api: "SYNO.Chat.Channel.GuestUser", method: record.method, version: 1, parameters: record.parameters)
    }

    /// Setup and password rewrapping only. Neither operation replaces channel
    /// content keys. Renewal/reset have separate contracts and cannot use this route.
    func applyEncryptionManagementPlan(_ plan: ChatEncryptionManagement.Plan, connectionID: String?) async throws {
        guard plan.channels.isEmpty, plan.archives.isEmpty,
              (try? ChatContentCrypto.decodeBase64(plan.replacement.public_key).count) == 32,
              (try? ChatContentCrypto.decodeBase64(plan.replacement.private_key_enc).count) == 84 else { throw ChatAPIError.invalidResponse }
        switch plan.operation {
        case .initialSetup:
            guard plan.original.public_key.isEmpty, plan.original.private_key_enc.isEmpty else { throw ChatAPIError.invalidResponse }
            try await callVoid(api: "SYNO.Chat.User", method: "set", version: 3,
                               parameters: ["public_key": .string(plan.replacement.public_key), "private_key_enc": .string(plan.replacement.private_key_enc)])
        case .passwordRewrap:
            guard plan.original.isInitialized, plan.original.public_key == plan.replacement.public_key,
                  let connectionID, !connectionID.isEmpty, connectionID.utf8.count <= 512 else { throw ChatAPIError.invalidResponse }
            try await callVoid(api: "SYNO.Chat.User", method: "change_password", version: 2,
                               parameters: ["conn_id": .string(connectionID), "private_key_enc": .string(plan.replacement.private_key_enc)])
        case .keyRenewal: throw ChatAPIError.unsupportedAPI
        }
    }

    func channelGuests(channelID: Int64) async throws -> [ChatChannelGuest] {
        guard channelID > 2 else { throw ChatAPIError.invalidResponse }
        let result: ChatChannelGuestList = try await call(api: "SYNO.Chat.Channel.GuestUser", method: "list", version: 1,
                                                       parameters: ["channel_id": .integer(channelID)])
        return try result.validated()
    }

    func createNamedChannel(name: String, purpose: String, kind: ChatNamedChannelKind,
                            onCreated:@MainActor (Int64) throws -> Void = { _ in },
                            checkContinuation: @MainActor () throws -> Void = { try Task.checkCancellation() }) async throws -> ChatChannel {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = ChatNamedChannelInput.validationError(name: name, purpose: purpose) { throw ChatTransferError(message: error) }
        try await checkContinuation()
        struct Created: Decodable { let channel_id: Int64 }
        let created: Created
        do {
            created = try await call(api: "SYNO.Chat.Channel.Named", method: "create", version: 1,
                parameters: ["name": .string(name), "purpose": .string(purpose), "type": .string(kind.rawValue), "encrypted": .bool(false)])
            guard created.channel_id > 0 else { throw ChatAPIError.invalidResponse }
        } catch ChatAPIError.server(let code) { throw ChatAPIError.server(code) }
        catch { throw ChatChannelCreationUnconfirmedError() }
        do {
            // Preserve a known created ID even when cancellation/account change stops joining.
            try await onCreated(created.channel_id)
            try await checkContinuation()
            try await callVoid(api: "SYNO.Chat.Channel.Named", method: "join", version: 1,
                               parameters: ["channel_id": .integer(created.channel_id), "channel_key_enc": .string("")])
            try await checkContinuation()
            guard let channel = try await channels().first(where: { $0.id == created.channel_id }),
                  channel.name == name, channel.type == kind.rawValue, !channel.encrypted else { throw ChatAPIError.invalidResponse }
            return channel
        } catch {
            // Creation may already be durable. Never repeat it or automatically delete the channel.
            throw ChatChannelCreatedError(channelID: created.channel_id)
        }
    }

    /// Wire foundation only. The caller must persist the creator envelope before
    /// calling and checkpoint the returned ID in onCreated, including after an
    /// account change. A callback failure prevents joining; no mutation retries.
    @MainActor func createEncryptedNamedChannel(name:String,purpose:String,plan:ChatEncryptedChannelCreation,
                                    owner:ChatEncryptionKeyPair,encryption:ChatEncryptionSession,
                                    onDispatch:@MainActor () throws -> Void = {},
                                    onCreated:@MainActor (Int64,String) throws -> Void,
                                    onJoinDispatch:@MainActor () throws -> Void = {},
                                    checkContinuation:@MainActor () async throws -> Void) async throws -> ChatChannel {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if let error = ChatNamedChannelInput.validationError(name:name,purpose:purpose) { throw ChatTransferError(message:error) }
        try plan.validate(owner:owner,encryption:encryption)
        try await checkContinuation()
        try plan.validate(owner:owner,encryption:encryption)
        struct Created:Decodable { let channel_id:Int64 }
        let created:Created
        try onDispatch()
        do {
            created = try await call(api:"SYNO.Chat.Channel.Named",method:"create",version:1,
                                     parameters:["name":.string(name),"purpose":.string(purpose),"type":.string("private"),"encrypted":.bool(true)])
            guard created.channel_id > 1 else { throw ChatAPIError.invalidResponse }
        } catch ChatAPIError.server(let code) { throw ChatAPIError.server(code) }
        catch { throw ChatChannelCreationUnconfirmedError() }
        do {
            try await onCreated(created.channel_id,plan.creatorEnvelope)
            try await checkContinuation()
            try plan.validate(owner:owner,encryption:encryption)
            try onJoinDispatch()
            try await callVoid(api:"SYNO.Chat.Channel.Named",method:"join",version:1,
                               parameters:["channel_id":.integer(created.channel_id),"channel_key_enc":.string(plan.creatorEnvelope)])
            try await checkContinuation()
            let current = try await channels()
            try await checkContinuation()
            try plan.validate(owner:owner,encryption:encryption)
            let matches = current.filter { $0.id == created.channel_id }
            guard matches.count == 1,let channel = matches.first,plan.matches(channel,name:name,purpose:purpose) else { throw ChatAPIError.invalidResponse }
            _ = try encryption.key(for:channel)
            return channel
        } catch { throw ChatChannelCreatedError(channelID:created.channel_id) }
    }

    /// One explicitly reviewed join using the original creator envelope. This
    /// cannot create a channel or generate/replace a channel content key.
    func joinEncryptedCreatedChannel(_ intent:ChatEncryptedCreationIntent,channel:ChatChannel) async throws {
        try intent.validate()
        guard intent.joinAttemptID != nil,intent.matchesUnjoined(channel),let id = intent.channelID else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel.Named",method:"join",version:1,
                           parameters:["channel_id":.integer(id),"channel_key_enc":.string(intent.creatorEnvelope)])
    }

    func inviteChannelMembers(_ ids: Set<Int64>, channel: ChatChannel) async throws {
        guard channel.isOrdinaryNamedChannel, channel.id != 1, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }) else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Channel.Named", method: "invite", version: 1,
            parameters: ["channel_id": .integer(channel.id), "user_ids": .array(ids.sorted().map(ChatParameter.integer)),
                         "channel_key_encs": .array([])])
    }

    /// Typed encrypted path only: the existing ordinary invite cannot emit empty
    /// envelopes for an encrypted channel. A fresh account coordinator must own
    /// ACL/membership/session checks and canonical confirmation around this call.
    func inviteEncryptedChannelMembers(_ plan:ChatEncryptedChannelInvitation,channel:ChatChannel,users:[ChatUser]) async throws {
        try plan.validate(channel:channel,users:users)
        try await callVoid(api:"SYNO.Chat.Channel.Named",method:"invite",version:1,
                           parameters:["channel_id":.integer(channel.id),"user_ids":.array(plan.userIDs.map(ChatParameter.integer)),
                                       "channel_key_encs":.array(plan.envelopes.map(ChatParameter.string))])
    }

    func removeChannelMember(_ userID: Int64, channel: ChatChannel) async throws {
        guard channel.supportsMemberRemoval, userID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Channel.Named", method: "kick", version: 1,
                          parameters: ["channel_id": .integer(channel.id), "user_id": .integer(userID)])
    }

    /// Match the official non-encrypted anonymous-channel initiation contract.
    /// Never retry automatically: the server may have created the channel before a response failed.
    func initiateConversation(userIDs: [Int64]) async throws -> ChatChannel {
        let ids = Array(Set(userIDs)).sorted()
        guard ids.count >= 2, ids.count == userIDs.count, ids.allSatisfy({ $0 > 0 }) else {
            throw ChatAPIError.invalidResponse
        }
        let channel: ChatChannel = try await call(api: "SYNO.Chat.Channel.Anonymous", method: "initiate", version: 2,
            // The ordinary profile/contact action omits the optional encryption flag.
            parameters: ["user_ids": .array(ids.map(ChatParameter.integer)), "channel_key_encs": .array([])])
        guard channel.id > 0, channel.type == "anonymous", !channel.encrypted else { throw ChatAPIError.invalidResponse }
        return channel
    }

    /// Single-dispatch encrypted wire operation. A caller must persist intent
    /// before calling, and confirm canonical membership/account/key scope before
    /// publishing the result. Never retry or fall back to ordinary initiation.
    func initiateEncryptedConversation(_ plan:ChatEncryptedConversationStart,owner:ChatEncryptionKeyPair,users:[ChatUser],encryption:ChatEncryptionSession) async throws -> ChatChannel {
        try Task.checkCancellation()
        try plan.validate(owner:owner,users:users,encryption:encryption)
        let channel:ChatChannel = try await call(api:"SYNO.Chat.Channel.Anonymous",method:"initiate",version:2,
            parameters:["user_ids":.array(plan.userIDs.map(ChatParameter.integer)),"encrypted":.bool(true),"channel_key_encs":.array(plan.envelopes.map(ChatParameter.string))])
        guard plan.matchesCreatedResponse(channel) else { throw ChatEncryptedConversationResponseUnconfirmed(candidateChannelID:channel.id > 0 ? channel.id : nil) }
        return channel
    }

    func members(channelID: Int64) async throws -> [Int64] {
        let data: MemberList = try await call(api: "SYNO.Chat.Channel.Member", method: "get", version: 1,
                                              parameters: ["channel_id": .integer(channelID)])
        return data.user_ids
    }

    func archiveNames(kind:ChatArchiveKind) async throws -> [String] {
        let data:ChatArchiveNames = try await call(api:"SYNO.Chat.Archive",method:"list_name",version:1,parameters:["type":.string(kind.rawValue)])
        guard Set(data.channel_names).count == data.channel_names.count else { throw ChatAPIError.invalidResponse }
        return data.channel_names
    }
    func archives(kind:ChatArchiveKind,name:String) async throws -> [ChatArchive] {
        let data:ChatArchiveList = try await call(api:"SYNO.Chat.Archive",method:"list",version:1,parameters:["type":.string(kind.rawValue),"channel_name":.string(name)])
        guard Set(data.archives.map(\.id)).count == data.archives.count else { throw ChatAPIError.invalidResponse }
        return data.archives.sorted { $0.post_end > $1.post_end }
    }
    func searchArchives(scopes:[ChatArchive],query:String,collection:ChatArchiveCollection,offset:Int = 0) async throws -> ChatArchiveSearchResult {
        guard !scopes.isEmpty,scopes.allSatisfy(\.isReadable),Set(scopes.map(\.id)).count == scopes.count,
              offset >= 0,offset <= Int.max - 25,query.utf16.count <= 1000 else { throw ChatAPIError.invalidResponse }
        var parameters:[String:ChatParameter] = ["archives":.array(scopes.map { .integer($0.id) }),"in":.array([]),"keyword":.string(query),"offset":.integer(Int64(offset)),"limit":.integer(25)]
        for (key,value) in collection.parameters { parameters[key] = value }
        let page:ChatSearchPage = try await call(api:"SYNO.Chat.Post",method:"search",version:5,parameters:parameters)
        guard page.search_results.count <= 25,page.total == nil || page.total! >= 0 else { throw ChatAPIError.invalidResponse }
        return .init(matches:try ChatArchiveMatch.resolve(page.search_results,scopes:scopes),total:page.total,nextOffset:offset + page.search_results.count)
    }
    func archiveContext(_ archive:ChatArchive,postID:Int64,threadID:Int64? = nil,exact:Bool = false) async throws -> [ChatPost] {
        guard archive.isReadable,postID > 0,postID >= archive.post_id_start,postID <= archive.post_id_end else { throw ChatAPIError.invalidResponse }
        var parameters:[String:ChatParameter] = ["archive_id":.integer(archive.id),"channel_id":.integer(archive.props.channel.id),"post_id":.integer(postID),"prev_count":.integer(exact ? 0 : 15),"next_count":.integer(exact ? 0 : 15)]
        if let threadID {
            guard threadID > 0,threadID >= archive.post_id_start,threadID <= archive.post_id_end else { throw ChatAPIError.invalidResponse }
            parameters["thread_id"] = .integer(threadID)
        }
        let page:PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,parameters:parameters)
        // Validate root separately because reply validation deliberately omits it from a thread page.
        _ = try archive.validatePosts(page.posts,before:nil,threadID:threadID)
        guard page.posts.contains(where:{ $0.id == postID }) else { throw ChatAPIError.invalidResponse }
        return page.posts.sorted { $0.id < $1.id }
    }

    func archivePosts(_ archive:ChatArchive,before:Int64? = nil,threadID:Int64? = nil) async throws -> [ChatPost] {
        guard archive.isReadable,before == nil || (before! > 0 && before! >= archive.post_id_start && before! <= archive.post_id_end) else { throw ChatAPIError.invalidResponse }
        if let before,before == archive.post_id_start { return [] }
        var parameters:[String:ChatParameter] = ["archive_id":.integer(archive.id),"channel_id":.integer(archive.props.channel.id),"prev_count":.integer(30),"next_count":.integer(0)]
        if let threadID {
            guard threadID > 0,threadID >= archive.post_id_start,threadID <= archive.post_id_end else { throw ChatAPIError.invalidResponse }
            parameters["thread_id"] = .integer(threadID)
        }
        if let before { parameters["post_id"] = .integer(before) }
        let data:PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,parameters:parameters)
        return try archive.validatePosts(data.posts,before:before,threadID:threadID)
    }

    func publicChannelPreviewPosts(_ channel:ChatChannel) async throws -> [ChatPost] {
        guard channel.canJoinUnencryptedPublic else { throw ChatAPIError.invalidResponse }
        let result:PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,
            parameters:["channel_id":.integer(channel.id),"prev_count":.integer(20),"next_count":.integer(0)])
        guard result.posts.count <= 20,Set(result.posts.map(\.id)).count == result.posts.count,
              result.posts.allSatisfy({ $0.id > 0 && $0.channel_id == channel.id }) else { throw ChatAPIError.invalidResponse }
        return result.posts.sorted { $0.id < $1.id }
    }

    func posts(channelID: Int64, before postID: Int64? = nil) async throws -> [ChatPost] {
        var params: [String: ChatParameter] = ["channel_id": .integer(channelID),
                                             "prev_count": .integer(30), "next_count": .integer(0)]
        if let postID { params["post_id"] = .integer(postID) }
        let data: PostList = try await call(api: "SYNO.Chat.Post", method: "list", version: 5, parameters: params)
        return data.posts
    }

    func newerPosts(channelID:Int64,after postID:Int64) async throws -> [ChatPost] {
        guard channelID > 0,postID > 0 else { throw ChatAPIError.invalidResponse }
        let page:PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,
            parameters:["channel_id":.integer(channelID),"post_id":.integer(postID),
                        "prev_count":.integer(0),"next_count":.integer(30)])
        return page.posts
    }

    func context(channelID: Int64, postID: Int64) async throws -> [ChatPost] {
        let page: PostList = try await call(api: "SYNO.Chat.Post", method: "list", version: 5,
            parameters: ["channel_id": .integer(channelID), "post_id": .integer(postID),
                         "prev_count": .integer(15), "next_count": .integer(15)])
        if page.posts.contains(where: { $0.id == postID }) { return page.posts }
        return ChatTimeline.merge(page.posts, [try await post(channelID: channelID, postID: postID)])
    }

    func imageHistory(channelID: Int64, anchorID: Int64, threadID: Int64?, direction: ChatImageHistoryDirection) async throws -> ChatImageHistoryPage {
        guard channelID > 0, anchorID > 0, threadID == nil || (threadID! > 0 && threadID! != anchorID) else { throw ChatAPIError.invalidResponse }
        var parameters: [String:ChatParameter] = ["channel_id":.integer(channelID),"post_id":.integer(anchorID),
            "prev_count":.integer(direction == .newer ? 0 : 50),"next_count":.integer(direction == .older ? 0 : 50),"file_type":.array([.string("image")])]
        if let threadID { parameters["thread_id"] = .integer(threadID) }
        let result: PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,parameters:parameters)
        return try ChatImageHistoryPage(posts:result.posts,channelID:channelID,anchorID:anchorID,threadID:threadID,direction:direction)
    }

    func post(channelID: Int64, postID: Int64, threadID: Int64? = nil) async throws -> ChatPost {
        var parameters: [String: ChatParameter] = ["channel_id": .integer(channelID), "post_id": .integer(postID),
                                                   "prev_count": .integer(0), "next_count": .integer(0)]
        if let threadID { parameters["thread_id"] = .integer(threadID) }
        let result: PostList = try await call(api: "SYNO.Chat.Post", method: "list", version: 5,
            parameters: parameters)
        let matches = result.posts.filter { $0.id == postID && $0.channel_id == channelID }
        guard matches.count == 1,let post = matches.first else {
            throw ChatAPIError.invalidResponse
        }
        return post
    }

    /// Do not retry automatically: a failed response can still mean the server accepted the post.
    func sendText(channelID: Int64, text: String, connectionID: String, threadID: Int64 = 0) async throws -> ChatPost {
        let post: ChatPost = try await call(api: "SYNO.Chat.Post", method: "create", version: 5,
            parameters: ["channel_id": .integer(channelID), "type": .string("normal"), "message": .string(text),
                         "is_thread": .bool(false), "thread_id": .integer(threadID), "conn_id": .string(connectionID)])
        // A success envelope alone does not establish compatibility with the official client.
        guard post.id > 0, post.type == "normal", post.channel_id == channelID,
              (post.thread_id ?? 0) == threadID, threadID == 0 || post.isReply else { throw ChatAPIError.invalidResponse }
        return post
    }

    func runtimeVersion() async throws -> String {
        struct Asset: Decodable { let version: String? }
        let url = credentials.baseURL.appendingPathComponent("webman/3rdparty/Chat/config")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await network.data(from: url) }
        catch { throw ChatAPIError.connection }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try? JSONDecoder().decode([String: [String: Asset]].self, from: data),
              let version = manifest["libs.skip.js"]?["SYNO.SDS.Chat.SocketIO"]?.version else {
            throw ChatAPIError.invalidResponse
        }
        return version
    }

    func setAdditionalHashtag(postID: Int64, hashtag: String, enabled: Bool) async throws {
        guard postID > 0, ChatHashtags.valid(hashtag) else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Post.Hashtag", method: enabled ? "set" : "delete", version: 1,
                           parameters: ["post_id": .integer(postID), "hashtag": .string(hashtag)])
    }

    func channelHashtags(channelID: Int64) async throws -> [String] {
        struct Result: Decodable { let hashtags: [String] }
        let result: Result = try await call(api:"SYNO.Chat.Channel.Hashtag",method:"list",version:1,parameters:["channel_id":.integer(channelID)])
        guard result.hashtags.count <= 10000 else { throw ChatAPIError.invalidResponse }
        return Array(Set(result.hashtags.filter(ChatHashtags.valid))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func conversationFiles(channelID: Int64, query: String, offset: Int, options: ChatLibraryFileOptions) async throws -> ChatSearchPage {
        guard channelID > 0, offset >= 0 else { throw ChatAPIError.invalidResponse }
        return try await call(api: "SYNO.Chat.Post", method: "search", version: 5, parameters: [
            "keyword": .string(query), "in": .array([.integer(channelID)]), "offset": .integer(Int64(offset)), "limit": .integer(25),
            "post_type": .array([.string("file")]), "file_type": .array(options.category == .images ? [.string("image")] : []),
            "sort_by": .string(options.sort.rawValue)])
    }

    func searchMessages(query: String, channelID: Int64?, offset: Int = 0, hashtag: String? = nil, filters: ChatSearchFilters = .init()) async throws -> ChatSearchPage {
        var filters = filters
        if let hashtag { guard ChatHashtags.valid(hashtag),channelID != nil else { throw ChatAPIError.invalidResponse };filters.hashtags.append(hashtag) }
        var parameters: [String:ChatParameter] = ["keyword":.string(query), "in":.array(channelID.map { [.integer($0)] } ?? []),
            "offset":.integer(Int64(offset)),"limit":.integer(25)]
        for (key,value) in try filters.parameters() { parameters[key] = value }
        return try await call(api:"SYNO.Chat.Post",method:"search",version:5,parameters:parameters)
    }

    func notificationPreferences() async throws -> ChatNotificationPreferences {
        struct Result: Decodable { let preferences: ChatNotificationPreferences }
        let result: Result = try await call(api: "SYNO.Chat.User.Preference", method: "get", version: 4, parameters: [:])
        guard result.preferences.notification_showmessage != nil, result.preferences.notification_mute != nil else {
            throw ChatAPIError.invalidResponse
        }
        return result.preferences
    }

    func revokeSession() async throws {
        try await callVoid(api: "SYNO.API.Auth", method: "logout", version: 1,
                          parameters: ["session": .string("chat")])
    }

    func enterChannel(_ id: Int64, connectionID: String) async throws {
        try await callVoid(api: "SYNO.Chat.Channel", method: "enter", version: 2,
                          parameters: ["channel_id": .integer(id), "conn_id": .string(connectionID)])
    }

    func leaveChannel(connectionID: String) async throws {
        try await callVoid(api: "SYNO.Chat.Channel", method: "leave", version: 2,
                          parameters: ["conn_id": .string(connectionID)])
    }

    func viewChannel(_ id: Int64, through timestamp: Int64, connectionID: String) async throws {
        try await callVoid(api: "SYNO.Chat.Channel", method: "view", version: 2,
                          parameters: ["channel_id": .integer(id), "last_view_at": .integer(timestamp),
                                       "conn_id": .string(connectionID)])
    }

    func viewThread(channelID: Int64, rootID: Int64) async throws {
        try await callVoid(api: "SYNO.Chat.Post.Subscribe", method: "view", version: 2,
            parameters: ["channel_id": .integer(channelID), "thread_id": .integer(rootID)])
    }

    func readStatus(postID:Int64) async throws -> ChatPostReadStatus {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        let result: ChatPostReadStatus = try await call(api:"SYNO.Chat.Post",method:"get_read_status",version:6,
                                                       parameters:["post_id":.integer(postID)])
        try result.validate()
        return result
    }

    func threadCollection(channelID: Int64, offset: Int = 0) async throws -> ChatThreadCollectionPage {
        guard channelID > 0, offset >= 0 else { throw ChatAPIError.invalidResponse }
        let result: ChatThreadCollectionPage = try await call(api:"SYNO.Chat.Post",method:"thread_list",version:5,
            parameters:["channel_id":.integer(channelID),"offset":.integer(Int64(offset)),"limit":.integer(25),"related_comment_count":.integer(1)])
        guard result.search_results.allSatisfy({ $0.channel_id == channelID && !$0.isReply }) else { throw ChatAPIError.invalidResponse }
        return result
    }
    func setThreadSubscription(postID: Int64, enabled: Bool) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post.Subscribe",method:enabled ? "create" : "delete",version:1,
                           parameters:["post_id":.integer(postID)])
    }

    func threadPosts(channelID: Int64, rootID: Int64, before postID: Int64? = nil) async throws -> [ChatPost] {
        var params: [String: ChatParameter] = ["channel_id": .integer(channelID), "thread_id": .integer(rootID),
                                               "prev_count": .integer(30), "next_count": .integer(0)]
        if let postID { params["post_id"] = .integer(postID) }
        let result: PostList = try await call(api: "SYNO.Chat.Post", method: "list", version: 5, parameters: params)
        return result.posts
    }

    /// Finite, anchor-inclusive reply window. A missing/deleted anchor is not
    /// synthesized or fetched separately. The optional echoed root is checked
    /// for membership and removed before callers reconcile the reply list.
    func threadWindow(channelID:Int64,rootID:Int64,postID:Int64,previous:Int = 30,next:Int = 30) async throws -> [ChatPost] {
        guard channelID > 0,rootID > 0,postID > 0,(0...30).contains(previous),(0...30).contains(next) else { throw ChatAPIError.invalidResponse }
        let result:PostList = try await call(api:"SYNO.Chat.Post",method:"list",version:5,
            parameters:["channel_id":.integer(channelID),"thread_id":.integer(rootID),"post_id":.integer(postID),
                        "prev_count":.integer(Int64(previous)),"next_count":.integer(Int64(next))])
        guard result.posts.count <= previous+next+2,Set(result.posts.map(\.id)).count == result.posts.count,
              result.posts.allSatisfy({ post in
                  post.id > 0 && post.channel_id == channelID && (post.id == rootID ? !post.isReply : post.thread_id == rootID)
              }) else { throw ChatAPIError.invalidResponse }
        let replies = result.posts.filter { $0.id != rootID }
        guard replies.count <= previous+next+1,replies.filter({ $0.id < postID }).count <= previous,
              replies.filter({ $0.id > postID }).count <= next else { throw ChatAPIError.invalidResponse }
        return replies.sorted { $0.id < $1.id }
    }

    func setPost(_ post: ChatPost, text: String) async throws {
        try await callVoid(api: "SYNO.Chat.Post", method: "set", version: 8,
            parameters: ["post_id": .integer(post.id), "channel_id": .integer(post.channel_id),
                         "thread_id": .integer(post.thread_id ?? 0), "message": .string(text)])
    }

    func editPost(_ post: ChatPost, text: String) async throws -> ChatPost {
        try await setPost(post, text: text)
        return try await self.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
    }

    func setPinSticky(postID: Int64, enabled: Bool) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Post", method: enabled ? "stick" : "unstick", version: 5,
                           parameters: ["post_id": .integer(postID)])
    }
    func setPinned(postID:Int64,enabled:Bool) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post",method:enabled ? "pin" : "unpin",version:5,parameters:["post_id":.integer(postID)])
    }
    /// The vendor endpoint returns no receipt. Confirm each destination separately; never retry automatically.
    func forwardPost(postID:Int64,channelIDs:[Int64]) async throws {
        guard postID > 0,!channelIDs.isEmpty,channelIDs.count <= 20,Set(channelIDs).count == channelIDs.count,channelIDs.allSatisfy({ $0 > 0 }) else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post",method:"forward",version:5,parameters:["post_id":.integer(postID),"channel_ids":.array(channelIDs.map(ChatParameter.integer))])
    }
    func changeConversationOrganization(channelID:Int64,change:ChatConversationOrganizationChange) async throws {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel",method:change.method,version:2,parameters:["channel_id":.integer(channelID)])
    }
    func reminderTime(postID:Int64) async throws -> Double {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        struct Value:Decodable { let remind_at:Double }
        let value:Value = try await call(api:"SYNO.Chat.Post.Reminder",method:"get",version:1,parameters:["post_id":.integer(postID)])
        guard ChatReminderTime.valid(value.remind_at) else { throw ChatAPIError.invalidResponse };return value.remind_at
    }
    func reminders(channelID:Int64) async throws -> [ChatReminder] {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        struct Page:Decodable { let posts:[ChatPost] }
        let page:Page = try await call(api:"SYNO.Chat.Post.Reminder",method:"list",version:1,parameters:["channel_id":.integer(channelID)])
        guard Set(page.posts.map(\.id)).count == page.posts.count,page.posts.allSatisfy({ $0.channel_id == channelID }) else { throw ChatAPIError.invalidResponse }
        return try page.posts.map(ChatReminder.init).sorted { $0.remindAt == $1.remindAt ? $0.id < $1.id : $0.remindAt < $1.remindAt }
    }
    func setReminder(postID:Int64,date:Date) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse };let time = try ChatReminderTime.future(date)
        try await callVoid(api:"SYNO.Chat.Post.Reminder",method:"set",version:1,parameters:["post_id":.integer(postID),"remind_at":.integer(Int64(time))])
    }
    func removeReminder(postID:Int64) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post.Reminder",method:"delete",version:1,parameters:["post_id":.integer(postID)])
    }
    func scheduledMessages(channelID:Int64) async throws -> [ChatScheduledMessage] {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        struct Page:Decodable { let schedule_posts:[ChatScheduledMessage] }
        let page:Page = try await call(api:"SYNO.Chat.Post.Schedule",method:"list",version:1,parameters:["channel_id":.integer(channelID)])
        guard Set(page.schedule_posts.map(\.id)).count == page.schedule_posts.count else { throw ChatAPIError.invalidResponse }
        try page.schedule_posts.forEach { try $0.validate() }
        return page.schedule_posts.sorted { $0.send_at == $1.send_at ? $0.id < $1.id : $0.send_at < $1.send_at }
    }
    func createScheduledMessage(channelID:Int64,draft:ChatScheduleDraft) async throws -> Int64 {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        let draft = try draft.validated()
        struct Created:Decodable { let cronjob_id:Int64 }
        let result:Created = try await call(api:"SYNO.Chat.Post.Schedule",method:"create",version:1,parameters:["channel_id":.integer(channelID),"message":.string(draft.message),"send_at":.integer(Int64(draft.milliseconds))])
        guard result.cronjob_id > 0 else { throw ChatAPIError.invalidResponse };return result.cronjob_id
    }
    func setScheduledMessage(id:Int64,draft:ChatScheduleDraft) async throws {
        guard id > 0 else { throw ChatAPIError.invalidResponse };let draft = try draft.validated()
        try await callVoid(api:"SYNO.Chat.Post.Schedule",method:"set",version:1,parameters:["cronjob_id":.integer(id),"message":.string(draft.message),"send_at":.integer(Int64(draft.milliseconds))])
    }
    func cancelScheduledMessage(id:Int64) async throws {
        guard id > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post.Schedule",method:"delete",version:1,parameters:["cronjob_id":.integer(id)])
    }
    func pinnedMessages(channelID:Int64,query:String,offset:Int,sort:ChatPinSort = .pinned) async throws -> ChatSearchPage {
        guard channelID > 0,offset >= 0 else { throw ChatAPIError.invalidResponse }
        return try await call(api:"SYNO.Chat.Post",method:"search",version:5,parameters:[
            "keyword":.string(query),"in":.array([.integer(channelID)]),"offset":.integer(Int64(offset)),"limit":.integer(25),
            "has":.array([.string("pin")]),"sort_by":.string(sort.rawValue),
            "sort_by_array":.array([.string("is_sticky"),.string(sort.rawValue)])])
    }

    func setBookmark(postID: Int64, enabled: Bool) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post",method:enabled ? "star" : "unstar",version:5,
                           parameters:["post_id":.integer(postID)])
    }

    func deletePost(postID: Int64) async throws {
        try await callVoid(api: "SYNO.Chat.Post", method: "delete", version: 8,
                           parameters: ["post_id": .integer(postID), "real_delete": .bool(false)])
    }

    func stickerCatalogue() async throws -> [ChatStickerPack] {
        let data: ChatStickerCatalogue = try await call(api: "SYNO.Chat.Sticker", method: "list", version: 1)
        guard data.categories.count <= 100, data.categories.flatMap(\.stickers).count <= 5000,
              data.categories.flatMap(\.stickers).allSatisfy({ ChatSticker.validName($0.name) }) else { throw ChatAPIError.invalidResponse }
        return data.categories
    }
    func stickerAssetData(path: String) async throws -> Data {
        guard path == "style.css" || path.range(of: #"^images/sticker/1x/[A-Za-z0-9_\-]+\.png$"#, options: .regularExpression) != nil else { throw ChatAPIError.invalidResponse }
        // Public NAS asset route: deliberately no session/token query, external
        // URLs, cookies or redirects. Preserve QuickConnect's resolved prefix.
        let url = credentials.baseURL.appendingPathComponent("webman/3rdparty/Chat").appendingPathComponent(path)
        let (bytes, response) = try await network.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              bytes.count <= 8 * 1024 * 1024,
              path == "style.css" ? http.mimeType == "text/css" : http.mimeType == "image/png" else { throw ChatAPIError.invalidResponse }
        return bytes
    }
    func setReaction(postID: Int64, sticker: ChatReactionKind, enabled: Bool) async throws {
        try await setReaction(postID: postID, stickerName: sticker.rawValue, enabled: enabled)
    }
    func setReaction(postID: Int64, stickerName: String, enabled: Bool) async throws {
        guard ChatReactionKind(rawValue: stickerName) != nil else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Post.Reaction", method: enabled ? "set" : "delete", version: 1,
                           parameters: ["post_id": .integer(postID), "sticker_name": .string(stickerName)])
    }
    func sendSticker(channelID: Int64, name: String, wireText: String, connectionID: String, threadID: Int64 = 0) async throws -> ChatPost {
        guard ChatSticker.validName(name) else { throw ChatAPIError.invalidResponse }
        let post: ChatPost = try await call(api: "SYNO.Chat.Post", method: "create", version: 5,
            parameters: ["channel_id": .integer(channelID), "type": .string("sticker"), "message": .string(wireText),
                         "is_thread": .bool(false), "thread_id": .integer(threadID), "conn_id": .string(connectionID)])
        guard post.id > 0, post.type == "sticker", post.channel_id == channelID,
              (post.thread_id ?? 0) == threadID, threadID == 0 || post.isReply else { throw ChatAPIError.invalidResponse }
        return post
    }

    func removeProfilePhoto() async throws {
        try await callVoid(api:"SYNO.Chat.User",method:"set",version:3,parameters:["remove_avatar":.bool(true)])
    }
    func uploadProfilePhoto(_ png:Data) async throws {
        guard !png.isEmpty,png.count <= 2*1024*1024,png.starts(with:[137,80,78,71,13,10,26,10]) else { throw ChatAPIError.invalidResponse }
        let boundary = "NativeChatAvatar"+UUID().uuidString
        var request = try requestForCall(api:"SYNO.Chat.User",method:"set",version:3)
        var route = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!
        route.queryItems = (route.queryItems ?? [])+[URLQueryItem(name:"api",value:"SYNO.Chat.User"),URLQueryItem(name:"method",value:"set"),URLQueryItem(name:"version",value:"3")]
        request.url = route.url
        var body = Data()
        for (key,value) in [("api","SYNO.Chat.User"),("method","set"),("version","3")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"profile.png\"\r\nContent-Type: image/png\r\n\r\n".utf8));body.append(png);body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body;request.setValue("multipart/form-data; boundary="+boundary,forHTTPHeaderField:"Content-Type");request.timeoutInterval = 60
        let _:APIEnvelope<ChatJSON> = try await performEnvelope(request)
    }

    func drivePolicy() async throws -> ChatDrivePolicy {
        struct Admin:Decodable {let allow_drive_upload:Bool}
        let admin:Admin = try await call(api:"SYNO.Chat.Admin.Setting",method:"get",version:5)
        guard admin.allow_drive_upload else {throw ChatTransferError(message:"Your server administrator has disabled Drive sharing.")}
        let policy:ChatDrivePolicy = try await call(api:"SYNO.SynologyDrive.Settings",method:"list",version:1)
        guard policy.allowsLinks else {throw ChatTransferError(message:"Drive link sharing is unavailable for this account.")};return policy
    }
    func driveFiles(location:ChatDriveLocation,folderID:String?,offset:Int,labelID:ChatDriveLabel.ID? = nil,query:String? = nil) async throws -> ChatDriveBrowsePage {
        guard offset >= 0,offset <= 1_000_000,folderID == nil || ChatDriveFile.validID(folderID!) else {throw ChatAPIError.invalidResponse}
        var parameters:[String:ChatParameter] = ["offset":.integer(Int64(offset)),"limit":.integer(100),"sort_by":.string("name"),"sort_direction":.string("asc")]
        if location == .labels && folderID == nil && labelID == nil && query == nil {
            struct Labels:Decodable {let items:[ChatDriveLabel];let total:Int}
            let page:Labels = try await call(api:"SYNO.SynologyDrive.Labels",method:"list",version:1,parameters:parameters)
            guard page.total >= offset,page.total <= 1_000_000,page.items.count <= min(100,page.total-offset),page.items.allSatisfy(\.valid),Set(page.items.map(\.id)).count == page.items.count else {throw ChatAPIError.invalidResponse}
            return .init(files:[],teams:[],labels:page.items,hasMore:offset+page.items.count < page.total)
        }
        if location == .teamFolders && folderID == nil && query == nil {
            struct Teams:Decodable {let items:[ChatDriveTeamFolder];let total:Int}
            let page:Teams = try await call(api:"SYNO.SynologyDrive.TeamFolders",method:"list",version:1,parameters:parameters)
            guard page.total >= offset,page.total <= 1_000_000,page.items.count <= min(100,page.total-offset),Set(page.items.map(\.id)).count == page.items.count,page.items.allSatisfy({ChatDriveFile.validID($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 4096}) else {throw ChatAPIError.invalidResponse}
            return .init(files:[],teams:page.items,hasMore:offset+page.items.count < page.total)
        }
        let method = query != nil ? "search" : (folderID == nil ? location.method : "list")
        if let query {
            guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,query.utf16.count <= 512,!query.contains("\0") else {throw ChatAPIError.invalidResponse}
            parameters["keyword"] = .string(query);parameters["location"] = .string("any");parameters["content_snippet"] = .bool(false);parameters["sort_by"] = .string("score")
        } else if location == .labels && folderID == nil {
            guard let labelID,labelID.valid else {throw ChatAPIError.invalidResponse};parameters["label_id"] = labelID.parameter
        }
        if let folderID {parameters["path"] = .string("id:"+folderID)} else if location == .myDrive && query == nil {parameters["path"] = .string("/mydrive")}
        parameters["filter"] = .object(["include_transient":.bool(true)])
        let page:ChatDrivePage = try await call(api:"SYNO.SynologyDrive.Files",method:method,version:2,parameters:parameters)
        guard page.items.count <= 100,Set(page.items.map(\.id)).count == page.items.count,page.items.allSatisfy(\.valid),page.total == nil || (page.total! >= offset+page.items.count && page.total! <= 1_000_000) else {throw ChatAPIError.invalidResponse}
        return .init(files:page.items,teams:[],hasMore:page.total.map {offset+page.items.count < $0} ?? (page.items.count == 100))
    }
    func driveFile(id:String) async throws -> ChatDriveFile {
        guard ChatDriveFile.validID(id) else {throw ChatAPIError.invalidResponse}
        let file:ChatDriveFile = try await call(api:"SYNO.SynologyDrive.Files",method:"get",version:2,parameters:["path":.string("id:"+id)])
        guard file.id == id,file.valid else {throw ChatAPIError.invalidResponse};return file
    }
    func updateDriveAccess(id:String,edits:[ChatParameter]) async throws {
        guard ChatDriveFile.validID(id),!edits.isEmpty,edits.count <= 1000 else {throw ChatAPIError.invalidResponse}
        try await callVoid(api:"SYNO.SynologyDrive.Sharing",method:"update",version:1,parameters:["path":.string("id:"+id),"permissions":.array(edits)])
    }
    func createDriveLink(id:String) async throws -> URL {
        guard ChatDriveFile.validID(id) else {throw ChatAPIError.invalidResponse}
        let link:ChatDriveLink = try await call(api:"SYNO.SynologyDrive.Sharing",method:"create_link",version:1,parameters:["path":.string("id:"+id)])
        guard let url = link.validatedURL(base:credentials.baseURL) else {throw ChatAPIError.invalidResponse};return url
    }

    func nasUploadPolicy() async throws -> ChatNASUploadPolicy {
        try await call(api:"SYNO.Chat.Admin.Setting",method:"get",version:5)
    }
    func nasRoots() async throws -> [ChatNASRoot] {
        let roots:[ChatNASRoot] = try await call(api:"SYNO.Core.File",method:"list",version:1,parameters:["folder_path":.string("/"),"status_filter":.string("valid"),"needrw":.bool(false),"superuser":.bool(false)])
        guard roots.count <= 1024,Set(roots.map(\.spath)).count == roots.count,roots.allSatisfy({!$0.spath.isEmpty && $0.spath.utf8.count <= 8192 && !$0.spath.contains("\0") && $0.spath != "/" && $0.text.utf8.count <= 1024}) else {throw ChatAPIError.invalidResponse}
        return roots.filter {$0.spath != "/home"}
    }
    func nasFiles(folder:String,offset:Int) async throws -> ChatNASPage {
        guard ChatNASFile.validPath(folder),folder != "/",offset >= 0,offset <= 1_000_000 else {throw ChatAPIError.invalidResponse}
        let page:ChatNASPage = try await call(api:"SYNO.Core.File",method:"list",version:1,parameters:["folder_path":.string(folder),"filetype":.string("all"),"offset":.integer(Int64(offset)),"limit":.integer(100),"sort_by":.string("name"),"sort_direction":.string("ASC"),"superuser":.bool(false),"additional":.array(["size","time","perm","type"].map(ChatParameter.string))])
        guard page.offset == offset,page.total >= offset,page.total <= 1_000_000,page.files.count <= 100,page.files.count <= page.total-offset,Set(page.files.map(\.path)).count == page.files.count,page.files.allSatisfy({$0.valid && ($0.path as NSString).deletingLastPathComponent == folder}) else {throw ChatAPIError.invalidResponse}
        return page
    }
    func nasFileInfo(_ path:String) async throws -> ChatNASFile {
        guard ChatNASFile.validPath(path) else {throw ChatAPIError.invalidResponse}
        struct Result:Decodable {let files:[ChatNASFile]}
        let result:Result = try await call(api:"SYNO.FileStation.List",method:"getinfo",version:2,parameters:["path":.array([.string(path)]),"additional":.array(["size","time","perm","type"].map(ChatParameter.string))])
        guard result.files.count == 1,let file = result.files.first,file.path == path,file.valid else {throw ChatAPIError.invalidResponse};return file
    }
    func sendNASFile(_ file:ChatNASFile,channelID:Int64,caption:String,connectionID:String,threadID:Int64) async throws -> ChatPost {
        guard file.selectable,channelID > 0,threadID >= 0,ChatMessageText.isAllowed(caption) else {throw ChatAPIError.invalidResponse}
        let post:ChatPost = try await call(api:"SYNO.Chat.Post",method:"create",version:5,parameters:["channel_id":.integer(channelID),"type":.string("file"),"message":.string(caption),"ds_file":.string(file.path),"is_thread":.bool(false),"thread_id":.integer(threadID),"conn_id":.string(connectionID)])
        guard post.id > 0,post.type == "file",post.channel_id == channelID,(post.thread_id ?? 0) == threadID,post.file_props?.name == file.name,post.file_props?.size == nil || post.file_props?.size == file.additional.size else {throw ChatAPIError.invalidResponse};return post
    }

    func launcherURL(for app:ChatLauncherApplication)->URL? {app.launchURL(baseURL:credentials.baseURL)}
    func launcherApplications() async throws -> [ChatLauncherApplication] {
        struct Result:Decodable {let applications:[ChatLauncherApplication];let total:Int}
        let result:Result = try await call(api:"SYNO.Personal.Application.Info",method:"get",version:1,parameters:["is_app_portal":.bool(true),"app_name":.string("SYNO.SDS.Chat.Application")])
        guard result.total == result.applications.count,result.applications.count <= 256,result.applications.allSatisfy(\.valid),Set(result.applications.map(\.appname)).count == result.applications.count else {throw ChatAPIError.invalidResponse}
        return result.applications
    }
    func setLauncherOrder(_ names:[String]) async throws {
        guard !names.isEmpty,names.count <= 256,Set(names).count == names.count,names.allSatisfy({!$0.isEmpty && $0.utf8.count <= 256}) else {throw ChatAPIError.invalidResponse}
        try await callVoid(api:"SYNO.Personal.Application.Info",method:"setorder",version:1,parameters:["app_order":.array(names.map(ChatParameter.string))])
    }

    func desktopPersonalSettings() async throws -> ChatDesktopPersonalSettings {
        let settings:ChatDesktopPersonalSettings = try await call(api:"SYNO.Core.UserSettings",method:"get",version:1)
        guard settings.Personal.count <= 512 else { throw ChatAPIError.invalidResponse };return settings
    }
    func emojiRecentSettings() async throws -> ChatEmojiRecentSettings {
        let data: ChatJSON = try await call(api:"SYNO.Core.UserSettings",method:"get",version:1)
        return try .init(data)
    }
    func applyEmojiRecentSettings(_ settings: ChatEmojiRecentSettings) async throws {
        let data = try JSONEncoder().encode(settings.payload)
        guard data.count <= 1024*1024 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Core.UserSettings",method:"apply",version:1,parameters:["data":.string(String(decoding:data,as:UTF8.self))])
    }
    func regionalDefaults() async throws -> ChatRegionalDefaults {
        try await call(api:"SYNO.Core.Desktop.Initdata",method:"get_user_service",version:1,parameters:["launch_app":.string("SYNO.SDS.Chat.Application")])
    }
    func regionalDisplay() async throws -> ChatRegionalDisplay {
        let personal = try await desktopPersonalSettings(),defaults = try await regionalDefaults()
        return .init(personal:personal,defaults:defaults)
    }
    func applyDesktopPersonalSettings(_ personal:[String:ChatJSON]) async throws {
        let data = try JSONEncoder().encode(ChatJSON.object(["Personal":.object(personal)]))
        guard data.count <= 1024*1024 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Core.UserSettings",method:"apply",version:1,parameters:["data":.string(String(decoding:data,as:UTF8.self))])
    }
    func regionalTimeZones() async throws -> [ChatTimeZoneOption] {
        struct Result:Decodable { let zonedata:[ChatTimeZoneOption] }
        let r:Result = try await call(api:"SYNO.Core.Region.NTP",method:"listzone",version:1)
        guard !r.zonedata.isEmpty,r.zonedata.count <= 1024,Set(r.zonedata.map(\.value)).count == r.zonedata.count,r.zonedata.allSatisfy({ !$0.value.isEmpty && $0.value.utf8.count <= 256 && $0.display.utf8.count <= 1024 && (-86400...86400).contains($0.offset) }) else { throw ChatAPIError.invalidResponse }
        return r.zonedata
    }
    func setProfileTimeZone(_ value:String) async throws {
        try await callVoid(api:"SYNO.Chat.User",method:"set",version:3,parameters:["timezone":.string(value == "def" ? "" : value)])
    }

    func pairedNotificationDevices() async throws -> [ChatPairedDevice] {
        struct Result:Decodable { let count:Int;let list:[ChatPairedDevice] }
        let result:Result = try await call(api:"SYNO.Personal.Notification.Device",method:"list",version:2,parameters:["package":.string("Chat")])
        guard result.count == result.list.count,result.list.count <= 256,result.list.allSatisfy(\.valid),Set(result.list.map(\.id)).count == result.list.count else { throw ChatAPIError.invalidResponse }
        return result.list
    }
    func unpairNotificationDevice(_ device:ChatPairedDevice) async throws {
        guard device.valid else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Personal.Notification.Device",method:"unpair",version:1,parameters:["package":.string("Chat"),"list":.array([device.parameter])])
    }

    func profileEditingPolicy() async throws -> ChatProfileEditingPolicy {
        try await call(api:"SYNO.Chat.Admin.Setting",method:"get",version:5)
    }
    func setProfileText(_ patch:[String:ChatParameter]) async throws {
        guard !patch.isEmpty,Set(patch.keys).isSubset(of:["nickname","description"]),patch.values.allSatisfy({ if case .string = $0 { return true };return false }) else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.User",method:"set",version:3,parameters:patch)
    }

    func displaySettings() async throws -> ChatDisplaySettings {
        try await call(api: "SYNO.Chat.Admin.Setting", method: "get", version: 5, parameters: [:])
    }
    func hideLinkPreview(postID: Int64, index: Int) async throws {
        guard index >= 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Post", method: "hide_og", version: 5,
                           parameters: ["post_id": .integer(postID), "idx": .integer(Int64(index))])
    }

    func callVoid(api: String, method: String, version: Int, parameters: [String: ChatParameter]) async throws {
        let request = try requestForCall(api: api, method: method, version: version, parameters: parameters)
        let _: APIEnvelope<ChatJSON> = try await performEnvelope(request)
    }

    private func call<T: Decodable>(api: String, method: String, version: Int,
                                    parameters: [String: ChatParameter] = [:]) async throws -> T {
        try await perform(requestForCall(api: api, method: method, version: version, parameters: parameters))
    }

    func requestForCall(api: String, method: String, version: Int,
                        parameters: [String: ChatParameter] = [:]) throws -> URLRequest {
        guard let endpoint = endpoints[api], endpoint.minVersion <= version, version <= endpoint.maxVersion else {
            throw ChatAPIError.unsupportedAPI
        }
        return try makeRequest(api: api, method: method, version: version, path: endpoint.path,
                               parameters: parameters, jsonParameters: endpoint.requestFormat == "JSON")
    }

    // Internal for protocol encoding tests; never log the resulting authenticated URL.
    func makeRequest(api: String, method: String, version: Int, path: String,
                     parameters: [String: ChatParameter], jsonParameters: Bool,
                     authenticated: Bool = true) throws -> URLRequest {
        guard !path.contains("/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else {
            throw ChatAPIError.invalidResponse
        }
        var components = URLComponents(url: credentials.baseURL, resolvingAgainstBaseURL: false)!
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        guard !basePath.hasSuffix(".cgi"), !basePath.hasSuffix(".html") else { throw ChatAPIError.invalidServer }
        components.path = basePath + "/webapi/" + path + "/" + api
        components.queryItems = authenticated ? [URLQueryItem(name: "_sid", value: credentials.sid),
                                                 URLQueryItem(name: "SynoToken", value: credentials.synoToken)] : nil
        components.fragment = nil
        guard let url = components.url else { throw ChatAPIError.invalidServer }
        var fields = ["api": api, "method": method, "version": String(version)]
        for (key, value) in parameters {
            guard fields[key] == nil, !["_sid", "SynoToken"].contains(key) else { throw ChatAPIError.invalidResponse }
            let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            if !jsonParameters, case .string(let raw) = value { fields[key] = raw }
            else { fields[key] = encoded }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        return request
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")).union(.init(charactersIn: "-._~"))
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return fields.keys.sorted().map { encode($0) + "=" + encode(fields[$0]!) }.joined(separator: "&")
    }

    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let envelope: APIEnvelope<T> = try await performEnvelope(request)
        guard let result = envelope.data else { throw ChatAPIError.invalidResponse }
        return result
    }

    private func performEnvelope<T: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<T> {
#if DEBUG
        try debugRequestGuard?(request)
#endif
        let data: Data
        let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ChatAPIError.connection }
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.invalidResponse }
        guard http.statusCode == 200 else { throw ChatAPIError.http(http.statusCode) }
        let envelope: APIEnvelope<T>
        do { envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data) }
        catch { throw ChatAPIError.invalidResponse }
        guard envelope.success else { throw ChatAPIError.server(envelope.error?.code ?? -1) }
        return envelope
    }
}

struct ChannelList: Decodable { let channels: [ChatChannel] }
struct UserList: Decodable { let users: [ChatUser] }
struct MemberList: Decodable { let user_ids: [Int64] }
struct PostList: Decodable { let posts: [ChatPost] }

enum ChatNamedChannelKind: String, CaseIterable { case `private`, `public` }
enum ChatNamedChannelInput {
    static func validationError(name: String, purpose: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let reserved = CharacterSet(charactersIn: "~!@{}<>`|?#$%^&*()+\\[]'\":;,/=")
            .union(.whitespacesAndNewlines).union(.controlCharacters)
        guard !name.isEmpty else { return "Enter a channel name." }
        guard name.utf16.count <= 64, !name.unicodeScalars.contains(where: reserved.contains) else {
            return "Use a channel name of up to 64 characters without spaces or reserved punctuation. Hyphens are allowed."
        }
        guard purpose.utf16.count <= 256 else { return "Keep the channel purpose within 256 characters." }
        return nil
    }
}
struct ChatChannelCreatedError: LocalizedError {
    let channelID: Int64
    var errorDescription: String? { "Channel \(channelID) was created, but joining or loading it could not be confirmed. Check it in Synology Chat before creating another channel." }
}
struct ChatChannelCreationUnconfirmedError: LocalizedError {
    var errorDescription: String? { "Creation could not be confirmed. Check Synology Chat before creating another channel; it may already exist." }
}
struct ChatChannelPermissions: Decodable {
    struct Entry: Decodable { let acl_name: String; let allow: Bool }
    let acls: [Entry]
    func allows(_ action: String) -> Bool {
        let matches = acls.filter { $0.acl_name == action }
        return !matches.isEmpty && matches.allSatisfy(\.allow)
    }
}

struct ChatChannel: Decodable, Identifiable, Hashable {
    let channel_id: Int64
    let name: String
    let type: String
    let creator_id: Int64?
    let encrypted: Bool
    let channel_key_enc: String?
    var unread: Int
    let channel_order_time: Double?
    let last_view_at: Double?
    let unread_mention: Int?
    let unread_thread: [String: Int]?
    let subscribes: [Int64]?
    let purpose:String?
    let total_member_count:Int?
    let is_closed:Bool?
    let is_star:Bool?
    let is_joined:Bool?
    let last_hide_at:Double?
    let hide_global_at:Double?
    let preferences:SidebarPreferences?
    struct SidebarPreferences:Decodable,Hashable { let notification_desktop:String? }

    var isOrdinaryNamedChannel: Bool { ["public", "private"].contains(type) && !encrypted }
    /// Removing a member uses IDs only, including when the channel key is locked.
    var supportsMemberRemoval: Bool {
        id > 1 && type == "private" && is_closed != true && is_joined != false && (hide_global_at ?? 0) <= 0
    }
    // Match the official client: direct/encrypted/bot chats count all unread
    // posts; named channels count mentions. Subscribed thread counts are additive.
    var badgeUnreadCount: Int {
        let primary = encrypted || ["anonymous","synobot","chatbot"].contains(type) ? unread : (unread_mention ?? 0)
        return (unread_thread ?? [:]).values.reduce(min(9999, max(0, primary))) {
            min(9999, $0 + min(9999, max(0, $1)))
        }
    }
    var id: Int64 { channel_id }
    var defaultTitle: String? {
        if type == "synobot" { return "My Space" }
        if !name.isEmpty { return name }
        if channel_id == 1 { return "General" }
        if channel_id == 2 { return "Random" }
        return nil
    }
}

struct ChatUser: Decodable {
    let user_id:Int64
    let username:String?
    let nickname:String
    let type:String?
    let human_type:String?
    let dsm_uid:Int64?
    let bot_type:String?
    let slash_props: ChatSlashProperties?
    let is_disabled:Bool?
    let delete_at:Double?
    let avatar_version:Int64?
    let app_id:String?
    struct Properties:Decodable {
        let key_pair:ChatEncryptionKeyPair?
        let email:String?
        let description:String?
        let timezone:String?
        let timezoneUTC:String?
        let avatar_color:String?
        let is_always_offline:Bool?
        enum CodingKeys:String,CodingKey { case key_pair,email,description,timezone,timezoneUTC,avatar_color,is_always_offline }
        init(copying value: Self?, encryptionPair: ChatEncryptionKeyPair) {
            key_pair = encryptionPair; email = value?.email; description = value?.description
            timezone = value?.timezone; timezoneUTC = value?.timezoneUTC
            avatar_color = value?.avatar_color; is_always_offline = value?.is_always_offline
        }
        init(from decoder:Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            key_pair = try c.decodeIfPresent(ChatEncryptionKeyPair.self,forKey:.key_pair)
            email = try? c.decode(String.self,forKey:.email);description = try? c.decode(String.self,forKey:.description)
            timezone = try? c.decode(String.self,forKey:.timezone);timezoneUTC = try? c.decode(String.self,forKey:.timezoneUTC)
            avatar_color = try? c.decode(String.self,forKey:.avatar_color)
            is_always_offline = try? c.decode(Bool.self,forKey:.is_always_offline)
        }
    }
    private(set) var user_props:Properties?
    func replacingEncryptionPair(_ pair: ChatEncryptionKeyPair) -> Self {
        var copy = self
        copy.user_props = .init(copying: user_props, encryptionPair: pair)
        return copy
    }
    enum CodingKeys:String,CodingKey { case user_id,username,nickname,type,human_type,dsm_uid,bot_type,slash_props,is_disabled,delete_at,avatar_version,app_id,user_props }
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        user_id = try c.decode(Int64.self,forKey:.user_id);username = try c.decodeIfPresent(String.self,forKey:.username);nickname = try c.decode(String.self,forKey:.nickname)
        type = try c.decodeIfPresent(String.self,forKey:.type);human_type = try c.decodeIfPresent(String.self,forKey:.human_type)
        dsm_uid = (try? c.decode(Int64.self,forKey:.dsm_uid)) ?? (try? c.decode(String.self,forKey:.dsm_uid)).flatMap(Int64.init)
        slash_props = try? c.decode(ChatSlashProperties.self, forKey: .slash_props)
        bot_type = try? c.decode(String.self,forKey:.bot_type);is_disabled = try c.decodeIfPresent(Bool.self,forKey:.is_disabled);delete_at = try c.decodeIfPresent(Double.self,forKey:.delete_at)
        avatar_version = try? c.decode(Int64.self,forKey:.avatar_version);app_id = try? c.decode(String.self,forKey:.app_id)
        user_props = try c.decodeIfPresent(Properties.self,forKey:.user_props)
    }
    var canStartConversation:Bool { type == "human" && human_type == "dsm" && is_disabled != true && (delete_at ?? 0) == 0 }
    var canViewProfile:Bool { user_id > 0 && is_disabled != true && (delete_at ?? 0) == 0 && (type == "human" || (type == "bot" && bot_type == "synobot")) }
    // Legacy nickname-first fallback. Native presentation uses the account-scoped formatter.
    var displayName:String { nickname.isEmpty ? (username ?? "User \(user_id)") : nickname }
    var profileTimeZone:TimeZone? { user_props?.timezoneUTC.flatMap(TimeZone.init(identifier:)) ?? user_props?.timezone.flatMap(TimeZone.init(identifier:)) }
}

struct ChatPost: Decodable, Identifiable {
    let post_id: Int64
    let channel_id: Int64
    let creator_id: Int64
    let system_props: ChatSystemEvent?
    let message: String
    let type: String
    let create_at: Double
    let delete_at: Double?
    let update_at: Double?
    let thread_id: Int64?
    let comment_count: Int?
    let is_star: Bool?
    let star_at: Double?
    let last_comment_at: Double?
    let last_pin_at: Double?
    let is_sticky: Bool?
    let file_props: ChatFileProperties?
    let hashtags: [String]?
    let hashtags_additional: [ChatAdditionalHashtag]?
    let reactions: [ChatReaction]?
    let url_props: [ChatLinkPreview]?
    let props: ChatPostProperties?
    enum CodingKeys: String, CodingKey {
        case post_id, channel_id, creator_id, system_props, message, type, create_at, delete_at, update_at, thread_id, comment_count, is_star, star_at, last_comment_at, last_pin_at, is_sticky, file_props, hashtags, hashtags_additional, reactions, url_props, props
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        post_id = try c.decode(Int64.self, forKey: .post_id)
        channel_id = try c.decode(Int64.self, forKey: .channel_id)
        creator_id = try c.decode(Int64.self, forKey: .creator_id)
        system_props = try? c.decode(ChatSystemEvent.self, forKey: .system_props)
        message = try c.decode(String.self, forKey: .message)
        type = try c.decode(String.self, forKey: .type)
        create_at = try c.decode(Double.self, forKey: .create_at)
        delete_at = try c.decodeIfPresent(Double.self, forKey: .delete_at)
        update_at = try c.decodeIfPresent(Double.self, forKey: .update_at)
        thread_id = try c.decodeIfPresent(Int64.self, forKey: .thread_id)
        comment_count = try c.decodeIfPresent(Int.self, forKey: .comment_count)
        is_star = try c.decodeIfPresent(Bool.self, forKey: .is_star)
        star_at = try c.decodeIfPresent(Double.self, forKey: .star_at)
        last_comment_at = try c.decodeIfPresent(Double.self, forKey: .last_comment_at)
        last_pin_at = try c.decodeIfPresent(Double.self, forKey: .last_pin_at)
        is_sticky = try c.decodeIfPresent(Bool.self, forKey: .is_sticky)
        file_props = try c.decodeIfPresent(ChatFileProperties.self, forKey: .file_props)
        hashtags = try c.decodeIfPresent([String].self, forKey: .hashtags)
        hashtags_additional = try c.decodeIfPresent([ChatAdditionalHashtag].self, forKey: .hashtags_additional)
        reactions = try c.decodeIfPresent([ChatReaction].self, forKey: .reactions)
        url_props = try? c.decode([ChatLinkPreview].self, forKey: .url_props)
        if c.contains(.props), !(try c.decodeNil(forKey: .props)) {
            props = (try? c.decode(ChatPostProperties.self, forKey: .props)) ?? ChatPostProperties(safeURL: false)
        } else { props = nil }
    }
    var isPinned: Bool { (last_pin_at ?? 0) > 0 }
    var id: Int64 { post_id }
    var date: Date { Date(timeIntervalSince1970: create_at / 1_000) }
    var isReply: Bool { (thread_id ?? 0) != 0 && thread_id != post_id }
}

struct ChatFileProperties: Decodable {
    let name: String?
    let size: Int64?
    let is_image: Bool?
    let is_snippet:Bool?
    let snippet_preview:String?
    let snippet_lines:Int?
    let snippet_preview_more:Bool?
    let type: String?
}

struct ChatReaction: Decodable, Identifiable {
    let sticker_name: String
    let user_ids: [Int64]
    var id: String { sticker_name }
}

struct ChatThreadCollectionPage: Decodable {
    let search_results: [ChatPost]
    let related_posts: [ChatPost]
    let total: Int?
}
struct ChatSearchPage: Decodable {
    let search_results: [ChatPost]
    let total: Int?
}

struct ChatNotificationPreferences: Decodable {
    let notification_showmessage: Bool?
    let notification_browser_active: Bool?
    let notification_mute: Bool?
    var snooze:Int64? = nil
    var snooze_schedule_enable:Bool? = nil
    var snooze_schedule_start:Int? = nil
    var snooze_schedule_end:Int? = nil
}

private extension ChatPollOptions {
    var wire:ChatParameter { .object(["multiple":.bool(multiple),"anonymous":.bool(anonymous),"add_option":.bool(add_option),"expire_at":.integer(Int64(expire_at))]) }
}
extension ChatAPIClient {
    func createPoll(channelID:Int64,draft:ChatPollDraft) async throws -> ChatPost {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        let draft = try draft.validated()
        let choices:ChatParameter = .array(draft.choices.map { .object(["text":.string($0.text)]) })
        let post:ChatPost = try await call(api:"SYNO.Chat.Post.Vote",method:"create",version:1,parameters:["channel_id":.integer(channelID),"message":.string(draft.question),"choices":choices,"options":draft.options.wire])
        guard post.type == "vote",post.id > 0,post.channel_id == channelID,!post.isReply,post.message == draft.question,post.props?.vote?.choices.map(\.text) == draft.choices.map(\.text),post.props?.vote?.options.multiple == draft.multiple,post.props?.vote?.options.anonymous == draft.anonymous,post.props?.vote?.options.add_option == draft.allowAdd else { throw ChatAPIError.invalidResponse };return post
    }
    func pollChoices(postID:Int64) async throws -> [ChatPollChoice] {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        struct Response:Decodable { let choices:[ChatPollChoice] }
        let result:Response = try await call(api:"SYNO.Chat.Post.Vote",method:"get_choices",version:1,parameters:["post_id":.integer(postID)])
        return result.choices
    }
    func votePoll(postID:Int64,choices:[String],connectionID:String?) async throws {
        guard postID > 0,choices.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 256 }),Set(choices).count == choices.count else { throw ChatAPIError.invalidResponse }
        var params:[String:ChatParameter] = ["post_id":.integer(postID),"choice_ids":.array(choices.map(ChatParameter.string))]
        if let connectionID { params["conn_id"] = .string(connectionID) }
        try await callVoid(api:"SYNO.Chat.Post.Vote",method:"vote",version:1,parameters:params)
    }
    func addPollOption(postID:Int64,text:String,connectionID:String?) async throws {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard postID > 0,!text.isEmpty,text.utf16.count <= 120 else { throw ChatPollError("Enter an option of up to 120 characters.") }
        var params:[String:ChatParameter] = ["post_id":.integer(postID),"text":.string(text)]
        if let connectionID { params["conn_id"] = .string(connectionID) }
        try await callVoid(api:"SYNO.Chat.Post.Vote",method:"create_option",version:1,parameters:params)
    }
    func closePoll(postID:Int64) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Post.Vote",method:"close",version:1,parameters:["post_id":.integer(postID)])
    }
    func editPoll(postID:Int64,channelID:Int64,draft:ChatPollDraft,full:Bool) async throws {
        let draft = try draft.validated()
        guard postID > 0,channelID > 0 else { throw ChatAPIError.invalidResponse }
        var params:[String:ChatParameter] = ["post_id":.integer(postID),"channel_id":.integer(channelID)]
        if full {
            params["message"] = .string(draft.question)
            params["choices"] = .array(draft.choices.map { value in
                var choice:[String:ChatParameter] = ["text":.string(value.text)]
                if let id = value.serverID { choice["id"] = .string(id) };return .object(choice)
            })
            params["options"] = draft.options.wire
        } else { params["options"] = .object(["add_option":.bool(draft.allowAdd),"expire_at":.integer(Int64(draft.options.expire_at))]) }
        try await callVoid(api:"SYNO.Chat.Post.Vote",method:"set",version:1,parameters:params)
    }
}

extension ChatAPIClient {
    func setSnippet(postID:Int64,draft:NativeSnippetDraft) async throws {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        let draft = try draft.validated()
        try await callVoid(api:"SYNO.Chat.Post.Snippet",method:"set",version:2,parameters:["post_id":.integer(postID),"file_name":.string(draft.filename),"message":.string(draft.caption),"snippet":.string(draft.content)])
    }
}

extension ChatAPIClient {
    func archivePrivateChannelHistory(_ channel:ChatChannel) async throws {
        guard channel.supportsHistoryArchiving else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel",method:"archive",version:2,parameters:["channel_id":.integer(channel.id)])
    }
}

extension ChatAPIClient {
    func channelStatus(id:Int64) async throws -> ChatChannel {
        guard id > 0 else { throw ChatAPIError.invalidResponse }
        struct Status:Decodable { let channel:ChatChannel }
        let value:Status = try await call(api:"SYNO.Chat.Channel",method:"get",version:4,parameters:["channel_id":.integer(id)])
        guard value.channel.id == id else { throw ChatAPIError.invalidResponse };return value.channel
    }
    func closeChatChannel(_ channel:ChatChannel) async throws {
        guard channel.supportsClosing else { throw ChatAPIError.invalidResponse }
        try await callVoid(api:"SYNO.Chat.Channel",method:"close",version:4,parameters:["channel_id":.integer(channel.id)])
    }
}

extension ChatAPIClient {
    func notificationSettings() async throws -> ChatNotificationSettings {
        struct Result:Decodable { let preferences:ChatNotificationSettings }
        let result:Result = try await call(api:"SYNO.Chat.User.Preference",method:"get",version:4)
        try result.preferences.validate();return result.preferences
    }
    func serverClock() async throws -> ChatServerClock {
        struct Result:Decodable { let time:Double }
        let start = Date().timeIntervalSince1970
        let result:Result = try await call(api:"SYNO.Chat.Misc",method:"ntp",version:1)
        let end = Date().timeIntervalSince1970
        guard result.time.isFinite,result.time > 0,result.time <= 8_000_000_000_000_000,end >= start,end-start <= 30 else { throw ChatAPIError.invalidResponse }
        return .init(offset:result.time/1000-(start+end)/2)
    }
    func setNotificationSettings(_ patch:[String:ChatParameter]) async throws {
        let allowed:Set<String> = ["notification_showmessage","notification_browser_active","notification_mute","snooze","snooze_schedule_enable","snooze_schedule_start","snooze_schedule_end"]
        guard !patch.isEmpty,Set(patch.keys).isSubset(of:allowed) else { throw ChatAPIError.invalidResponse }
        for (key,value) in patch {
            switch (key,value) {
            case ("snooze",.integer(let time)):guard (0...8_000_000_000_000_000).contains(time) else { throw ChatAPIError.invalidResponse }
            case ("snooze_schedule_start",.integer(let time)),("snooze_schedule_end",.integer(let time)):guard (0..<86400).contains(time),time%1800 == 0 else { throw ChatAPIError.invalidResponse }
            case ("notification_showmessage",.bool),("notification_browser_active",.bool),("notification_mute",.bool),("snooze_schedule_enable",.bool):break
            default:throw ChatAPIError.invalidResponse
            }
        }
        let enablingSchedule:Bool
        if case .bool(true)? = patch["snooze_schedule_enable"] { enablingSchedule = true } else { enablingSchedule = false }
        if patch["snooze_schedule_start"] != nil || patch["snooze_schedule_end"] != nil || enablingSchedule {
            guard case .bool(true)? = patch["snooze_schedule_enable"],case .integer(let start)? = patch["snooze_schedule_start"],case .integer(let end)? = patch["snooze_schedule_end"],start != end else { throw ChatAPIError.invalidResponse }
        }
        try await callVoid(api:"SYNO.Chat.User.Preference",method:"set",version:4,parameters:patch)
    }
}

extension ChatAPIClient {
    func setManualAway(_ away:Bool) async throws {
        // The authenticated user is implicit. Do not include profile fields or a
        // user_id: this is the same dirty-field request as the official toggle.
        try await callVoid(api:"SYNO.Chat.User",method:"set",version:3,parameters:["is_always_offline":.bool(away)])
    }
}

extension ChatAPIClient {
    func channelAlerts(channelID: Int64) async throws -> ChatChannelAlerts {
        guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        struct Result: Decodable { let preferences: ChatChannelAlerts }
        let result: Result = try await call(api: "SYNO.Chat.Channel.Preference", method: "get", version: 3, parameters: ["channel_id": .integer(channelID)])
        try result.preferences.validate(); return result.preferences
    }
    func setChannelAlerts(channel: ChatChannel, patch: [String: String]) async throws {
        guard channel.id > 0, channel.is_closed != true, channel.is_joined != false, ["public","private","anonymous","synobot","chatbot"].contains(channel.type), !patch.isEmpty, Set(patch.keys).isSubset(of: ["notification_desktop", "notification_mobile"]),
              patch.values.allSatisfy({ raw in ChatChannelAlertMode.choices(channel).contains { $0.rawValue == raw } }) else { throw ChatAPIError.invalidResponse }
        var fields = patch.mapValues(ChatParameter.string); fields["channel_id"] = .integer(channel.id)
        try await callVoid(api: "SYNO.Chat.Channel.Preference", method: "set", version: 3, parameters: fields)
    }
}

extension ChatAPIClient {
    func sidebarSettings() async throws -> ChatSidebarSettings {
        struct Result: Decodable { let preferences: ChatSidebarSettings }
        let result: Result = try await call(api:"SYNO.Chat.User.Preference",method:"get",version:4,parameters:[:])
        return result.preferences
    }
    func setSidebarSettings(_ settings: ChatSidebarSettings) async throws {
        try await callVoid(api:"SYNO.Chat.User.Preference",method:"set",version:4,parameters:["sidebar_pinning_unread":.bool(settings.sidebar_pinning_unread)])
    }
}

extension ChatAPIClient {
    func nameSettings() async throws -> ChatNameSettings {
        struct Result: Decodable { let preferences: ChatNameSettings }
        let result: Result = try await call(api:"SYNO.Chat.User.Preference",method:"get",version:4,parameters:[:])
        return result.preferences
    }
    func setNameSettings(_ settings: ChatNameSettings) async throws {
        try await callVoid(api:"SYNO.Chat.User.Preference",method:"set",version:4,parameters:["prefer_user_name_format":.string(settings.prefer_user_name_format.rawValue)])
    }
}

extension ChatAPIClient {
    /// The fixed server catalogue is static artwork, never an arbitrary remote URL.
    func appearanceWallpaper(_ settings: ChatAppearanceSettings) async throws -> Data? {
        guard settings.background.rawValue != 0 else { return nil }
        let filename = String(format: "wallpaper_%@_%02d.jpg", settings.style.rawValue, settings.background.rawValue)
        var components = URLComponents(url: credentials.baseURL.appendingPathComponent("webman/3rdparty/Chat/images/theme/2x/" + filename), resolvingAgainstBaseURL: false)
        components?.query = nil; components?.fragment = nil
        guard let url = components?.url else { throw ChatAPIError.invalidServer }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        // Same pinned TLS/redirect policy as the API, without SID/token/cookies.
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image/jpeg",
              !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width <= 16_000_000 / height else {
            throw ChatAPIError.invalidResponse
        }
        return data
    }
}

