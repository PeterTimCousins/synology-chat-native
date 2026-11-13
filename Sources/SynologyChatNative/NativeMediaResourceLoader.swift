import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation may ask past EOF, resume a partially supplied request, or use
/// NSIntegerMax for an all-to-end request. Clip before adding to avoid overflow.
struct NativeMediaRequestWindow: Equatable {
    let start: Int64
    let end: Int64 // Exclusive, at most the known resource size.
    init(requestedOffset: Int64, currentOffset: Int64, requestedLength: Int,
         allToEnd: Bool, total: Int64) throws {
        guard total > 0, total <= 128 * 1024 * 1024,
              requestedOffset >= 0, requestedOffset <= total, currentOffset >= 0,
              currentOffset == 0 || currentOffset >= requestedOffset else { throw ChatMediaRangeReadError.invalidResponse }
        let start = currentOffset == 0 ? requestedOffset : currentOffset
        let end: Int64
        if allToEnd { end = total }
        else {
            guard requestedLength >= 0, let length = Int64(exactly: requestedLength) else { throw ChatMediaRangeReadError.invalidResponse }
            end = requestedOffset + min(length, total - requestedOffset)
        }
        guard start <= end else { throw ChatMediaRangeReadError.invalidResponse }
        self.start = start; self.end = end
    }
}

/// AVFoundation receives only an opaque app URL. The owner supplies authenticated
/// bounded reads and keeps this delegate alive for the asset's entire lifetime.
@MainActor final class NativeMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    typealias Read = @MainActor (ChatMediaByteRange) async throws -> Data
    let url: URL
    private(set) var lastError: Error?
    var activeRequestCount: Int { active.count }
    private let byteCount: Int64
    private let contentType: String
    private let read: Read
    private weak var asset: AVURLAsset?
    private var disposed = false
    private var active: [ObjectIdentifier: Pending] = [:]
    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        let token = UUID()
        var task: Task<Void, Never>?
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }

    init(filename: String, byteCount: Int64, read: @escaping Read) throws {
        let ext = (filename as NSString).pathExtension.lowercased()
        let supported = ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf"]
        guard byteCount > 0, byteCount <= 128 * 1024 * 1024 else { throw ChatMediaRangeReadError.invalidResponse }
        guard supported.contains(ext), let type = UTType(filenameExtension: ext),
              type.conforms(to: .audio) || type.conforms(to: .movie) else { throw ChatMediaRangeReadError.unsupported }
        guard let url = URL(string: "native-chat-media://\(UUID().uuidString.lowercased())/media.\(ext)")
        else { throw ChatMediaRangeReadError.invalidResponse }
        self.url = url; self.byteCount = byteCount; self.read = read; contentType = type.identifier
        super.init()
    }
    func attach(to asset: AVURLAsset) {
        guard !disposed, asset.url == url, self.asset == nil || self.asset === asset else {
            recordError(ChatMediaRangeReadError.invalidResponse); return
        }
        self.asset = asset
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !disposed, loadingRequest.request.url == url else { return false }
        let key = ObjectIdentifier(loadingRequest)
        guard active[key] == nil else { return true }
        guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return false }
        guard active.count < 8 else {
            failImmediately(loadingRequest, error: ChatMediaRangeReadError.invalidResponse); return true
        }
        if let info = loadingRequest.contentInformationRequest {
            guard let responseType = Self.allowedContentType(contentType, allowed: info.allowedContentTypes) else {
                failImmediately(loadingRequest, error: ChatMediaRangeReadError.invalidResponse); return true
            }
            info.contentType = responseType
            info.contentLength = byteCount
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(); return true
        }
        let window: NativeMediaRequestWindow
        do {
            window = try .init(requestedOffset: dataRequest.requestedOffset, currentOffset: dataRequest.currentOffset,
                               requestedLength: dataRequest.requestedLength, allToEnd: dataRequest.requestsAllDataToEndOfResource,
                               total: byteCount)
        } catch { failImmediately(loadingRequest, error: error); return true }
        let pending = Pending(loadingRequest)
        active[key] = pending
        pending.task = Task { @MainActor [weak self, weak pending] in
            guard let self, let pending else { return }
            do {
                var cursor = window.start
                while cursor < window.end {
                    try Task.checkCancellation()
                    guard self.isCurrent(key, pending) else { return }
                    let range = try ChatMediaByteRange(offset: cursor, length: Int(min(64 * 1024, window.end - cursor)), total: self.byteCount)
                    let bytes = try await self.read(range)
                    try Task.checkCancellation()
                    guard self.isCurrent(key, pending) else { return }
                    guard bytes.count == range.expectedCount else { throw ChatMediaRangeReadError.invalidResponse }
                    dataRequest.respond(with: bytes)
                    cursor += Int64(bytes.count)
                    await Task.yield()
                }
                self.finish(key, pending, error: nil)
            } catch { self.finish(key, pending, error: error) }
        }
        return true
    }
    /// The SDK requires contentType to be a member of a nonempty allowed list
    /// (not merely a subtype). Select that allowed ancestor when appropriate.
    static func allowedContentType(_ identifier: String, allowed: [String]?) -> String? {
        guard let allowed, !allowed.isEmpty else { return identifier }
        if allowed.contains(identifier) { return identifier }
        guard let type = UTType(identifier) else { return nil }
        return allowed.first { candidate in
            guard let parent = UTType(candidate) else { return false }
            return type.conforms(to: parent)
        }
    }
    private func isCurrent(_ key: ObjectIdentifier, _ pending: Pending) -> Bool {
        !disposed && active[key]?.token == pending.token && !pending.request.isCancelled && !pending.request.isFinished
    }
    private func finish(_ key: ObjectIdentifier, _ pending: Pending, error: Error?) {
        guard active[key]?.token == pending.token else { return }
        active.removeValue(forKey: key)
        guard !disposed, !pending.request.isCancelled, !pending.request.isFinished else { return }
        if let error {
            recordError(error)
            pending.request.finishLoading(with: error)
        } else { pending.request.finishLoading() }
    }
    private func recordError(_ error: Error) {
        guard lastError == nil, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        lastError = error
    }
    private func failImmediately(_ request: AVAssetResourceLoadingRequest, error: Error) {
        recordError(error)
        if !request.isCancelled, !request.isFinished { request.finishLoading(with: error) }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        guard let pending = active.removeValue(forKey: key) else { return }
        pending.task?.cancel()
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        asset?.resourceLoader.setDelegate(nil, queue: nil); asset = nil
        let requests = Array(active.values); active.removeAll()
        for pending in requests {
            pending.task?.cancel()
            if !pending.request.isCancelled, !pending.request.isFinished { pending.request.finishLoading(with: CancellationError()) }
        }
    }
}
