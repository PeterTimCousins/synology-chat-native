import Foundation

/// Bounds actual received bytes, including responses with no trustworthy Content-Length.
/// The session inherits the normal attachment configuration and pinned TLS/redirect policy.
final class ChatBoundedPreviewTransfer: NoChatRedirects, URLSessionDataDelegate {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var received = Data()

    init(maximumBytes: Int, tlsIdentity: ChatTLSIdentity?) {
        self.maximumBytes = maximumBytes
        super.init(tlsIdentity: tlsIdentity)
    }

    func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        received = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private var tooLarge: Error {
        ChatTransferError(message: "This document is too large to preview. Save the original to open it.")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Disposition") != nil else {
            completionHandler(.cancel)
            finish(.failure(ChatAPIError.invalidResponse))
            return
        }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? response.expectedContentLength
        guard declaredLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(tooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard data.count <= maximumBytes - received.count else {
            lock.unlock()
            finish(.failure(tooLarge))
            return
        }
        received.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : ChatAPIError.connection))
        } else {
            lock.lock()
            let result = received
            lock.unlock()
            finish(.success(result))
        }
    }
}
