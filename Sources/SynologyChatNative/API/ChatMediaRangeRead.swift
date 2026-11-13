import Foundation

enum ChatMediaRangeReadError: LocalizedError, Equatable {
    case unsupported, invalidResponse, alreadyUsed, connection
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This server does not support bounded media range requests."
        case .invalidResponse: return "The server returned an invalid media range response."
        case .alreadyUsed: return "A media range reader can only be used once."
        case .connection: return "The media range could not be read securely."
        }
    }
}

struct ChatMediaByteRange: Equatable {
    let offset: Int64
    let length: Int
    let total: Int64
    init(offset: Int64, length: Int, total: Int64) throws {
        guard total > 0, total <= 128 * 1024 * 1024, offset >= 0, offset < total,
              length > 0, length <= 1024 * 1024 else { throw ChatMediaRangeReadError.invalidResponse }
        self.offset = offset; self.length = length; self.total = total
    }
    var expectedCount: Int { Int(min(Int64(length), total - offset)) }
    var end: Int64 { offset + Int64(expectedCount) - 1 }
    var header: String { "bytes=\(offset)-\(end)" }
    var contentRange: String { "bytes \(offset)-\(end)/\(total)" }
}

/// A single authenticated, bounded in-memory read. Credentials remain in this
/// request/session; no URL or body is handed to a player or written to disk.
final class ChatMediaRangeRead: NoChatRedirects, URLSessionDataDelegate {
    private let range: ChatMediaByteRange
    private let lock = NSLock()
    private var used = false
    private var retired = false
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var received = Data()
    private var acceptedResponse = false

    init(range: ChatMediaByteRange, tlsIdentity: ChatTLSIdentity?) {
        self.range = range; super.init(tlsIdentity: tlsIdentity)
    }
    private func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !used else { throw ChatMediaRangeReadError.alreadyUsed }; used = true
    }
    func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        // Claim before installing the cancellation handler: a cancelled second
        // caller must never retire the first caller's active request.
        try claim()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !retired else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                var request = request
                request.setValue(range.header, forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        retired = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        received = Data(); acceptedResponse = false
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(ChatMediaRangeReadError.invalidResponse)); return
        }
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard http.statusCode != 200 else {
            completionHandler(.cancel)
            finish(.failure(disposition == "attachment" ? ChatMediaRangeReadError.unsupported : ChatMediaRangeReadError.invalidResponse))
            return
        }
        guard http.statusCode == 206, http.value(forHTTPHeaderField: "Content-Range") == range.contentRange,
              disposition == "attachment", encoding == nil || encoding == "identity" else {
            completionHandler(.cancel); finish(.failure(ChatMediaRangeReadError.invalidResponse)); return
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  UInt64(length) == UInt64(range.expectedCount) else {
                completionHandler(.cancel); finish(.failure(ChatMediaRangeReadError.invalidResponse)); return
            }
        }
        lock.lock()
        guard !retired, !acceptedResponse else {
            lock.unlock(); completionHandler(.cancel); finish(.failure(ChatMediaRangeReadError.invalidResponse)); return
        }
        acceptedResponse = true
        lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        guard acceptedResponse, data.count <= range.expectedCount - received.count else {
            lock.unlock(); finish(.failure(ChatMediaRangeReadError.invalidResponse)); return
        }
        received.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : ChatMediaRangeReadError.connection))
        } else {
            lock.lock()
            let valid = !retired && acceptedResponse && received.count == range.expectedCount
            let result = received
            lock.unlock()
            finish(valid ? .success(result) : .failure(ChatMediaRangeReadError.invalidResponse))
        }
    }
}
