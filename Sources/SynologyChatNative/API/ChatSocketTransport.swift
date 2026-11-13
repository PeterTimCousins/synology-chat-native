import Foundation

@MainActor
protocol ChatSocketTransport: AnyObject {
    var messages: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error> { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel()
}

/// Finish our receive stream immediately on cancellation. URLSession's graceful
/// WebSocket close can otherwise leave a pending receive waiting for the peer.
@MainActor
final class ChatURLSessionSocket: ChatSocketTransport {
    let messages: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>
    private let continuation: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.Continuation
    private let socket: URLSessionWebSocketTask
    private var reader: Task<Void, Never>?

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
        var source: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.Continuation!
        messages = AsyncThrowingStream { source = $0 }
        continuation = source
    }

    func resume() {
        guard reader == nil else { return }
        socket.resume()
        let socket = socket
        let output = continuation
        reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard !Task.isCancelled else { break }
                    output.yield(message)
                }
                output.finish()
            } catch { output.finish(throwing: error) }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func cancel() {
        continuation.finish(throwing: CancellationError())
        reader?.cancel(); reader = nil
        socket.cancel(with: .goingAway, reason: nil)
    }
    deinit {
        continuation.finish()
        reader?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }
}
