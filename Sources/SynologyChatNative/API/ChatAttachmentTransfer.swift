import Foundation

struct ChatTransferError: LocalizedError {
    let message: String
    /// A create request may have reached the server without a usable receipt.
    /// Callers must use this state rather than interpreting translated prose.
    let deliveryNeedsReview: Bool
    init(message:String,deliveryNeedsReview:Bool = false) {
        self.message = message;self.deliveryNeedsReview = deliveryNeedsReview
    }
    var errorDescription: String? { message }
}

/// Build large multipart bodies on disk in chunks, rather than retaining the whole attachment in RAM.
enum ChatMultipartBody {
    static func postFields(channelID: Int64, caption: String, connectionID: String, threadID: Int64 = 0) -> [String: String] {
        // Official ordinary-file uploads omit is_thread. Multipart fields are raw
        // strings: sending "false" can be treated as truthy by this upload route.
        ["api": "SYNO.Chat.Post", "method": "create", "version": "5", "channel_id": String(channelID),
         "type": "file", "message": caption, "thread_id": String(threadID), "conn_id": connectionID]
    }

    struct PreparedPost {
        let body: URL
        let wireFilename: String
    }

    static func preparePost(file: URL, channelID: Int64, caption: String, connectionID: String,
                            threadID: Int64, boundary: String, limitBytes: Int64, encryptionKey: Data?) throws -> PreparedPost {
        guard let encryptionKey else {
            let fields = postFields(channelID: channelID, caption: caption, connectionID: connectionID, threadID: threadID)
            return try PreparedPost(body: write(file: file, fields: fields, boundary: boundary, limitBytes: limitBytes),
                                    wireFilename: safeFilename(file.lastPathComponent))
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ChatTransferError(message: "Choose a regular file to attach.") }
        // Match Synology's 2^25-byte plaintext cap; account for ciphertext overhead at the server limit.
        let maximum = limitBytes > 0 ? min(Int64(1 << 25), max(0, limitBytes - 40)) : Int64(1 << 25)
        guard let size = values.fileSize, Int64(size) <= maximum, limitBytes == 0 || limitBytes >= 40 else {
            throw ChatTransferError(message: "This file exceeds the encrypted attachment size limit.")
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var plaintext = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard Int64(plaintext.count) + Int64(chunk.count) <= maximum else {
                throw ChatTransferError(message: "This file exceeds the encrypted attachment size limit.")
            }
            plaintext.append(chunk)
        }
        try Task.checkCancellation()
        let ciphertext = try ChatContentCrypto.encryptAttachment(plaintext, key: encryptionKey)
        let wireFilename = try ChatContentCrypto.encryptFilename(safeFilename(file.lastPathComponent), key: encryptionKey)
        let wireCaption = try ChatContentCrypto.encryptMessage(caption, key: encryptionKey)
        try Task.checkCancellation()
        // Only ciphertext is staged; the plaintext source remains in its original location.
        let encryptedFile = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-encrypted-upload-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: encryptedFile.path, contents: ciphertext, attributes: [.posixPermissions: 0o600]) else {
            throw ChatTransferError(message: "Could not prepare the encrypted attachment.")
        }
        defer { try? FileManager.default.removeItem(at: encryptedFile) }
        let fields = postFields(channelID: channelID, caption: wireCaption, connectionID: connectionID, threadID: threadID)
        return try PreparedPost(body: write(file: encryptedFile, fields: fields, boundary: boundary, limitBytes: limitBytes, filename: wireFilename),
                                wireFilename: wireFilename)
    }

    static func safeFilename(_ input: String) -> String {
        let leaf = (input.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let filtered = String(leaf.unicodeScalars.map { scalar -> Character in
            if scalar.value < 32 || scalar.value == 127 || scalar == "\"" { return "_" }
            return Character(String(scalar))
        })
        return filtered.isEmpty || [".", "..", "/"].contains(filtered) ? "attachment" : filtered
    }

    static func write(file: URL, fields: [String: String], boundary: String, limitBytes: Int64, filename: String? = nil) throws -> URL {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ChatTransferError(message: "Choose a regular file to attach.") }
        if limitBytes > 0, Int64(values.fileSize ?? 0) > limitBytes {
            throw ChatTransferError(message: "This file exceeds the server's attachment size limit.")
        }
        let temporary = try NativeSnippetTemporaryFiles.shared.create(filename:"multipart.body")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ChatTransferError(message: "Could not prepare the attachment. Check available disk space.")
        }
        var succeeded = false
        defer { if !succeeded { NativeSnippetTemporaryFiles.shared.remove(temporary) } }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        func text(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
        for key in fields.keys.sorted() {
            guard key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                throw ChatAPIError.invalidResponse
            }
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
        }
        try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename(filename ?? file.lastPathComponent))\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var transferred: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            transferred += Int64(chunk.count)
            if limitBytes > 0, transferred > limitBytes { throw ChatTransferError(message: "This file exceeds the server's attachment size limit.") }
            try output.write(contentsOf: chunk)
        }
        try text("\r\n--\(boundary)--\r\n")
        succeeded = true
        return temporary
    }
}

extension ChatAPIClient {
    private func attachmentNetwork(onUploadProgress: ChatUploadProgressCallback? = nil) -> URLSession {
        if let makeAttachmentNetwork { return makeAttachmentNetwork() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: makeConnectionDelegate(onUploadProgress: onUploadProgress), delegateQueue: nil)
    }
    func uploadAttachment(channelID: Int64, file: URL, caption: String, connectionID: String, threadID: Int64 = 0, encryptionKey: Data? = nil,
                          onProgress: ChatUploadProgressCallback? = nil) async throws -> ChatPost {
        struct Settings: Decodable { let file_size_limit: Double? }
        let prepared: ChatMultipartBody.PreparedPost
        let request: URLRequest
        var stagedBody: URL?
        do {
            try Task.checkCancellation()
            let files = try ChatAttachmentSelection.localFiles([file])
            try ChatAttachmentSelection.requireAvailable(files)
            let settingsRequest = try requestForCall(api: "SYNO.Chat.Admin.Setting", method: "get", version: 5)
            let settings: Settings = try await perform(settingsRequest)
            try Task.checkCancellation()
            let megabytes = settings.file_size_limit ?? 0
            guard megabytes >= 0, megabytes < Double(Int64.max) / (1024 * 1024) else { throw ChatAPIError.invalidResponse }
            let limit = Int64(megabytes * 1024 * 1024)
            let boundary = "NativeChat-" + UUID().uuidString
            prepared = try ChatMultipartBody.preparePost(file: file, channelID: channelID, caption: caption,
                connectionID: connectionID, threadID: threadID, boundary: boundary, limitBytes: limit, encryptionKey: encryptionKey)
            stagedBody = prepared.body
            try Task.checkCancellation()
            var upload = try requestForCall(api: "SYNO.Chat.Post", method: "create", version: 5)
            upload.httpBody = nil
            // Keep operation routing in the query before the server parses the streamed multipart body.
            guard var routing = URLComponents(url: upload.url!, resolvingAgainstBaseURL: false) else { throw ChatAPIError.invalidResponse }
            routing.queryItems = (routing.queryItems ?? []) + [URLQueryItem(name: "api", value: "SYNO.Chat.Post"),
                URLQueryItem(name: "method", value: "create"), URLQueryItem(name: "version", value: "5")]
            guard let url = routing.url else { throw ChatAPIError.invalidResponse };upload.url = url
            try ChatAttachmentSelection.requireAvailable([prepared.body])
            let attributes = try FileManager.default.attributesOfItem(atPath: prepared.body.path)
            guard let bodyBytes = attributes[.size] as? NSNumber, bodyBytes.int64Value > 0 else { throw ChatAPIError.invalidResponse }
            upload.setValue(bodyBytes.stringValue, forHTTPHeaderField: "Content-Length")
            upload.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            upload.timeoutInterval = 300
            try Task.checkCancellation()
            request = upload
        } catch {
            if let stagedBody { NativeSnippetTemporaryFiles.shared.remove(stagedBody) }
            // No Post/create upload has been handed to URLSession at this point.
            throw ChatAttachmentPreflightFailure(error)
        }
        let body = prepared.body
        defer { NativeSnippetTemporaryFiles.shared.remove(body) }
        let data: Data; let response: URLResponse
        let transferNetwork = attachmentNetwork(onUploadProgress: onProgress)
        defer { transferNetwork.invalidateAndCancel() }
        do { (data, response) = try await transferNetwork.upload(for: request, fromFile: body) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ChatTransferError(message: "Upload delivery could not be confirmed. Check the conversation before uploading again.",deliveryNeedsReview:true)
        }
        let unconfirmed = ChatTransferError(message: "Upload delivery could not be confirmed. Check the conversation before uploading again.",deliveryNeedsReview:true)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw unconfirmed }
        struct Upload: Decodable {
            struct Failure: Decodable { let code: Int }
            let success: Bool; let data: ChatPost?; let error: Failure?
        }
        guard let envelope = try? JSONDecoder().decode(Upload.self, from: data) else { throw unconfirmed }
        guard envelope.success else { throw ChatAPIError.server(envelope.error?.code ?? -1) }
        guard let post = envelope.data, post.id > 0, post.type == "file", post.channel_id == channelID,
              (post.thread_id ?? 0) == threadID else {
            throw ChatTransferError(message: "The upload response has unexpected message or conversation details. Check the conversation before trying again.",deliveryNeedsReview:true)
        }
        if encryptionKey != nil, post.file_props?.name != prepared.wireFilename {
            throw ChatTransferError(message: "The upload was accepted, but its encrypted filename is unexpected. Check the conversation before trying again.",deliveryNeedsReview:true)
        }
        return post
    }

    enum ImagePreviewSize: String { case medium = "M", large = "XL" }
    func thumbnail(postID: Int64, size: ImagePreviewSize = .medium) async throws -> Data {
        let request = try requestForCall(api: "SYNO.Chat.Post.File", method: "thumbnail", version: 2,
            parameters: ["post_id": .integer(postID), "type": .string(size.rawValue)])
        let data: Data; let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch { throw ChatAPIError.connection }
        let gif = data.starts(with:Data("GIF87a".utf8)) || data.starts(with:Data("GIF89a".utf8))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true || (http.mimeType == "application/octet-stream" && gif),data.count <= (size == .large ? 16 : 4) * 1024 * 1024 else { throw ChatAPIError.invalidResponse }
        return data
    }

    /// Encrypted images use the authenticated original; the server cannot resize their plaintext.
    /// Only ciphertext reaches temporary storage. Decoded preview bytes remain in memory.
    func encryptedImageData(postID: Int64, key: Data) async throws -> Data {
        let request = try requestForCall(api: "SYNO.Chat.Post.File", method: "get", version: 2,
                                         parameters: ["post_id": .integer(postID)])
        let transferNetwork = attachmentNetwork()
        defer { transferNetwork.invalidateAndCancel() }
        let downloaded: URL; let response: URLResponse
        do { (downloaded, response) = try await transferNetwork.download(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ChatAPIError.connection
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Disposition") != nil else { throw ChatAPIError.invalidResponse }
        let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= (1 << 25) + 40 else { throw ChatTransferError(message: "This encrypted image exceeds the preview size limit.") }
        let plaintext = try ChatContentCrypto.decryptAttachment(Data(contentsOf: downloaded), key: key)
        try Task.checkCancellation()
        return plaintext
    }

    func snippetText(postID:Int64) async throws -> String {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api:"SYNO.Chat.Post.Snippet",method:"get",version:1,parameters:["post_id":.integer(postID)])
        let transfer = attachmentNetwork();defer { transfer.invalidateAndCancel() }
        let file:URL,response:URLResponse
        do { (file,response) = try await transfer.download(for:request) }
        catch { if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() };throw ChatAPIError.connection }
        defer { try? FileManager.default.removeItem(at:file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,http.mimeType == "text/plain",
              let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= NativeSnippetDraft.maximumBytes else { throw ChatAPIError.invalidResponse }
        let data = try Data(contentsOf:file)
        guard let value = String(data:data,encoding:.utf8),!value.contains("\0") else { throw ChatAPIError.invalidResponse }
        try Task.checkCancellation();return value
    }

    func documentPreviewData(postID:Int64,maximumBytes:Int,decryptionKey:Data? = nil) async throws -> Data {
        guard postID > 0,maximumBytes > 0,maximumBytes <= 128 * 1024 * 1024 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api:"SYNO.Chat.Post.File",method:"get",version:2,parameters:["post_id":.integer(postID)])
        let template = attachmentNetwork()
        let configuration = template.configuration
        template.invalidateAndCancel()
        let transfer = ChatBoundedPreviewTransfer(maximumBytes: maximumBytes + (decryptionKey == nil ? 0 : 40),
                                                  tlsIdentity: makeConnectionDelegate().tlsIdentity)
        let data = try await transfer.load(request, configuration: configuration)
        try Task.checkCancellation()
        let plaintext = try decryptionKey.map { try ChatContentCrypto.decryptAttachment(data,key:$0) } ?? data
        try Task.checkCancellation()
        guard plaintext.count <= maximumBytes else { throw ChatAPIError.invalidResponse }
        return plaintext
    }

    func mediaRangeData(postID: Int64, range: ChatMediaByteRange) async throws -> Data {
        guard postID > 0 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api: "SYNO.Chat.Post.File", method: "get", version: 2,
                                         parameters: ["post_id": .integer(postID)])
        let template = attachmentNetwork()
        let configuration = template.configuration
        template.invalidateAndCancel()
        return try await ChatMediaRangeRead(range: range, tlsIdentity: makeConnectionDelegate().tlsIdentity)
            .load(request, configuration: configuration)
    }

    func saveAttachment(postID: Int64, to destination: URL, decryptionKey: Data? = nil, onProgress: ChatDownloadProgressCallback? = nil, authorizeCommit:(@MainActor (@escaping () throws -> Void) async throws -> Void)? = nil) async throws {
        guard ChatSavedDownloadFile.validDestination(destination), !destination.hasDirectoryPath else { throw ChatTransferError(message: "Choose a local file or a mounted folder for the saved attachment.") }
        let request = try requestForCall(api: "SYNO.Chat.Post.File", method: "get", version: 2,
                                         parameters: ["post_id": .integer(postID)])
        let downloaded: URL; let response: URLResponse
        let transferNetwork = attachmentNetwork()
        defer { transferNetwork.invalidateAndCancel() }
        do { (downloaded, response) = try await transferNetwork.download(for: request, delegate: makeConnectionDelegate(onDownloadProgress: onProgress)) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ChatTransferError(message: "Could not download the attachment. Check your connection and try again.")
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Disposition") != nil else {
            // The normal API error envelope can otherwise look like a successfully downloaded file.
            throw ChatTransferError(message: "The server did not return an attachment. Your sign-in may have expired.")
        }
        let wireSize = Int64((try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        onProgress?(wireSize, response.expectedContentLength)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".native-chat-" + UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            if let decryptionKey {
                let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                // Official encrypted-file maximum is 2^25 plaintext bytes plus the 40-byte envelope.
                guard size <= (1 << 25) + 40 else { throw ChatTransferError(message: "This encrypted file exceeds the supported size.") }
                let plaintext = try ChatContentCrypto.decryptAttachment(Data(contentsOf: downloaded), key: decryptionKey)
                try Task.checkCancellation()
                guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw ChatTransferError(message: "Could not prepare the saved attachment.")
                }
                try plaintext.write(to: staged)
            } else {
                try FileManager.default.copyItem(at: downloaded, to: staged)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try Task.checkCancellation()
            let commit = {
                try Task.checkCancellation()
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory) {
                    guard !directory.boolValue else { throw ChatTransferError(message: "Choose a filename instead of replacing a folder.") }
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else { try FileManager.default.moveItem(at: staged, to: destination) }
            }
            if let authorizeCommit { try await authorizeCommit(commit) } else { try commit() }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatCryptoError { throw error }
        catch let error as ChatTransferError { throw error }
        catch { throw ChatTransferError(message: "Could not save the attachment to that location. Choose another location and try again.") }
    }
}

extension ChatAPIClient {
    /// The official vote/create route accepts one multipart file or one ds_file.
    /// Preparation is known-unsent; once handed to the network, no retry is made.
    func createPoll(channelID:Int64,draft:ChatPollDraft,attachment:ChatPollAttachment,
                    authorize:@escaping @MainActor () throws -> Void) async throws -> ChatPost {
        let request:URLRequest
        var body:URL?
        do {
            var parameters = try draft.createParameters(channelID:channelID)
            switch attachment {
            case .nas(let file):
                guard file.selectable else { throw ChatPollError("Choose a readable NAS file.") }
                let policy = try await nasUploadPolicy();try await authorize()
                guard policy.allows(file) else { throw ChatPollError("NAS attachments are disabled or this file exceeds the server limit.") }
                let current = try await nasFileInfo(file.path);try await authorize()
                guard file.matchesForSend(current) else { throw ChatPollError("The NAS file changed. Remove it and choose it again.") }
                parameters["ds_file"] = .string(file.path)
                request = try requestForCall(api:"SYNO.Chat.Post.Vote",method:"create",version:1,parameters:parameters)
            case .local(let file):
                try file.requireUnchanged()
                struct Settings:Decodable { let file_size_limit:Double? }
                let settings:Settings = try await perform(requestForCall(api:"SYNO.Chat.Admin.Setting",method:"get",version:5));try await authorize()
                let mb = settings.file_size_limit ?? 0
                guard mb.isFinite,mb >= 0,mb < Double(Int64.max)/(1024*1024) else { throw ChatAPIError.invalidResponse }
                let boundary = "NativePoll-"+UUID().uuidString,fields = try draft.multipartFields(channelID:channelID)
                try file.requireUnchanged()
                let prepared = try ChatMultipartBody.write(file:file.url,fields:fields,boundary:boundary,limitBytes:Int64(mb*1024*1024));body = prepared
                try file.requireUnchanged()
                var upload = try requestForCall(api:"SYNO.Chat.Post.Vote",method:"create",version:1);upload.httpBody = nil
                guard let original = upload.url,var routing = URLComponents(url:original,resolvingAgainstBaseURL:false) else { throw ChatAPIError.invalidResponse }
                routing.queryItems = (routing.queryItems ?? []) + [URLQueryItem(name:"api",value:"SYNO.Chat.Post.Vote"),URLQueryItem(name:"method",value:"create"),URLQueryItem(name:"version",value:"1")]
                guard let url = routing.url else { throw ChatAPIError.invalidResponse };upload.url = url
                let size = try FileManager.default.attributesOfItem(atPath:prepared.path)[.size] as? NSNumber
                guard let size,size.int64Value > 0 else { throw ChatAPIError.invalidResponse }
                upload.setValue(size.stringValue,forHTTPHeaderField:"Content-Length");upload.setValue("multipart/form-data; boundary="+boundary,forHTTPHeaderField:"Content-Type");upload.timeoutInterval = 300;request = upload
            }
            try Task.checkCancellation();try await authorize();try Task.checkCancellation()
        } catch { if let body { NativeSnippetTemporaryFiles.shared.remove(body) };throw ChatPollCreationFailure.unsent(error) }
        defer { if let body { NativeSnippetTemporaryFiles.shared.remove(body) } }
        do {
            let post:ChatPost
            if let body {
                let network = attachmentNetwork();defer { network.invalidateAndCancel() }
                let (bytes,response) = try await network.upload(for:request,fromFile:body)
                guard let response = response as? HTTPURLResponse,response.statusCode == 200 else { throw ChatPollCreationFailure.uncertain }
                struct Envelope:Decodable { struct Failure:Decodable { let code:Int };let success:Bool;let data:ChatPost?;let error:Failure? }
                guard let result = try? JSONDecoder().decode(Envelope.self,from:bytes) else { throw ChatPollCreationFailure.uncertain }
                guard result.success else { guard let failure = result.error else { throw ChatPollCreationFailure.uncertain };throw ChatAPIError.server(failure.code) }
                guard let value = result.data else { throw ChatPollCreationFailure.uncertain };post = value
            } else { post = try await perform(request) }
            try draft.requireCreated(post,channelID:channelID,attachment:attachment)
            return post
        } catch let error as ChatAPIError {
            if case .server = error { throw error };throw ChatPollCreationFailure.uncertain
        } catch { throw ChatPollCreationFailure.uncertain }
    }
}
