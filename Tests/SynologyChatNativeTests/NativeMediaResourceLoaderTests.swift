import XCTest
import AVFoundation
@testable import SynologyChatNative

@MainActor final class NativeMediaResourceLoaderTests: XCTestCase {
    private func asset(_ loader: NativeMediaResourceLoader) -> AVURLAsset {
        let asset = AVURLAsset(url: loader.url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        loader.attach(to: asset); return asset
    }
    private func metadata(_ asset: AVURLAsset, loader: NativeMediaResourceLoader, mediaType: AVMediaType) async throws -> Double {
        let operation = Task { @MainActor in
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            let duration = try await asset.load(.duration).seconds
            guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else { throw ChatMediaRangeReadError.invalidResponse }
            return duration
        }
        let watchdog = Task { @MainActor in
            try await Task.sleep(nanoseconds: 8_000_000_000)
            asset.cancelLoading(); loader.dispose(); operation.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: {
            operation.cancel()
            Task { @MainActor in asset.cancelLoading(); loader.dispose() }
        })
    }
    private func slice(_ bytes: Data, _ range: ChatMediaByteRange) throws -> Data {
        guard range.total == Int64(bytes.count), range.offset >= 0,
              range.end < Int64(bytes.count), range.expectedCount <= 64 * 1024 else { throw ChatMediaRangeReadError.invalidResponse }
        return bytes.subdata(in: Int(range.offset)..<(Int(range.end) + 1))
    }
    func testRequestedWindowsClipResumeAndIgnoreAllToEndSentinelLengthWithoutOverflow() throws {
        XCTAssertEqual(try NativeMediaRequestWindow(requestedOffset: 5, currentOffset: 0, requestedLength: Int.max, allToEnd: false, total: 20),
                       try NativeMediaRequestWindow(requestedOffset: 5, currentOffset: 5, requestedLength: 15, allToEnd: false, total: 20))
        let resumed = try NativeMediaRequestWindow(requestedOffset: 5, currentOffset: 8, requestedLength: 10, allToEnd: false, total: 20)
        XCTAssertEqual(resumed.start, 8); XCTAssertEqual(resumed.end, 15)
        let all = try NativeMediaRequestWindow(requestedOffset: 5, currentOffset: 0, requestedLength: -1, allToEnd: true, total: 20)
        XCTAssertEqual(all.start, 5); XCTAssertEqual(all.end, 20)
        let eof = try NativeMediaRequestWindow(requestedOffset: 20, currentOffset: 20, requestedLength: Int.max, allToEnd: false, total: 20)
        XCTAssertEqual(eof.start, eof.end)
        for (requested, current, length) in [(Int64(-1), Int64(0), 1), (21, 0, 1), (5, 4, 10), (5, -1, 10), (5, 16, 10), (5, 0, -1)] {
            XCTAssertThrowsError(try NativeMediaRequestWindow(requestedOffset: requested, currentOffset: current, requestedLength: length, allToEnd: false, total: 20))
        }
    }
    func testAllowedUTISupertypesAreReturnedAsListedInsteadOfViolatingSDKMembershipContract() {
        let wave = "com.microsoft.waveform-audio"
        XCTAssertEqual(NativeMediaResourceLoader.allowedContentType(wave, allowed: ["public.audio"]), "public.audio")
        XCTAssertEqual(NativeMediaResourceLoader.allowedContentType("public.mpeg-4", allowed: ["public.movie"]), "public.movie")
        XCTAssertNil(NativeMediaResourceLoader.allowedContentType(wave, allowed: ["com.adobe.pdf"]))
        XCTAssertEqual(NativeMediaResourceLoader.allowedContentType(wave, allowed: []), wave)
    }
    func testOpaqueURLAndFilenameValidationExposeNoOriginalNameOrCredentials() throws {
        let one = try NativeMediaResourceLoader(filename: "private-financial-label.WAV", byteCount: 100, read: { _ in Data() })
        let two = try NativeMediaResourceLoader(filename: "private-financial-label.wav", byteCount: 100, read: { _ in Data() })
        XCTAssertEqual(one.url.scheme, "native-chat-media"); XCTAssertNotEqual(one.url, two.url)
        XCTAssertEqual(one.url.path, "/media.wav"); XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(one.url.host)))
        XCTAssertNil(one.url.user); XCTAssertNil(one.url.password); XCTAssertNil(one.url.query); XCTAssertNil(one.url.fragment)
        XCTAssertFalse(one.url.absoluteString.contains("financial"))
        for (name, size) in [("file.html", Int64(100)), ("file", 100), ("file.wav", 0), ("file.mp4", 128 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try NativeMediaResourceLoader(filename: name, byteCount: size, read: { _ in Data() }))
        }
        do { _ = try NativeMediaResourceLoader(filename: "unknown-format.xyz", byteCount: 100, read: { _ in Data() }); XCTFail() }
        catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .unsupported) }
        do { _ = try NativeMediaResourceLoader(filename: "valid.wav", byteCount: 0, read: { _ in Data() }); XCTFail() }
        catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        one.dispose(); two.dispose()
    }
    #if DEBUG
    func testActualAVAssetLoadsWaveMetadataFromBoundedInjectedBytesWithoutAFileURL() async throws {
        let bytes = NativeSyntheticMedia.wave(); var ranges: [ChatMediaByteRange] = []
        let loader = try NativeMediaResourceLoader(filename: "synthetic.wav", byteCount: Int64(bytes.count)) { range in
            XCTAssertTrue(Thread.isMainThread); ranges.append(range); return try self.slice(bytes, range)
        }
        let asset = asset(loader); defer { loader.dispose() }
        let duration = try await metadata(asset, loader: loader, mediaType: .audio)
        XCTAssertEqual(duration, 3, accuracy: 0.05); XCTAssertFalse(asset.url.isFileURL)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
        XCTAssertFalse(ranges.isEmpty); XCTAssertTrue(ranges.allSatisfy { $0.expectedCount > 0 && $0.expectedCount <= 64 * 1024 })
        XCTAssertNil(loader.lastError)
    }
    func testActualAVAssetLoadsVideoMetadataThroughOpaqueResourceLoader() async throws {
        // Only this test fixture is generated on disk; the adapter receives Data
        // slices and never creates or exposes a playback temporary file.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-resource-video-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.mp4")
        try await NativeSyntheticMedia.video(to: file)
        let bytes = try Data(contentsOf: file); var reads = 0
        let loader = try NativeMediaResourceLoader(filename: "fixture.mp4", byteCount: Int64(bytes.count)) { range in
            reads += 1; return try self.slice(bytes, range)
        }
        let asset = asset(loader); defer { loader.dispose() }
        let duration = try await metadata(asset, loader: loader, mediaType: .video)
        XCTAssertGreaterThan(duration, 2.8); XCTAssertGreaterThan(reads, 0); XCTAssertNil(loader.lastError)
    }
    func testReadErrorsAndIncorrectByteCountsFailWithoutSupplyingStalePartialBytes() async throws {
        let bytes = NativeSyntheticMedia.wave()
        for unsupported in [false, true] {
            var reads = 0
            let loader = try NativeMediaResourceLoader(filename: "synthetic.wav", byteCount: Int64(bytes.count)) { range in
                reads += 1
                if unsupported { throw ChatMediaRangeReadError.unsupported }
                return Data(repeating: 0, count: max(0, range.expectedCount - 1))
            }
            let asset = asset(loader)
            do { _ = try await metadata(asset, loader: loader, mediaType: .audio); XCTFail("Invalid media read accepted") } catch { }
            XCTAssertGreaterThan(reads, 0)
            XCTAssertEqual(loader.lastError as? ChatMediaRangeReadError, unsupported ? .unsupported : .invalidResponse)
            XCTAssertEqual(loader.activeRequestCount, 0); loader.dispose()
        }
    }
    func testDisposeRetiresPendingRequestsBeforeUncooperativeReadReturns() async throws {
        let bytes = NativeSyntheticMedia.wave(), started = expectation(description: "AV requested bytes")
        let gate = BlockingMediaReads(started: started)
        let loader = try NativeMediaResourceLoader(filename: "synthetic.wav", byteCount: Int64(bytes.count)) { range in try await gate.read(range) }
        let asset = asset(loader)
        let task = Task { try await metadata(asset, loader: loader, mediaType: .audio) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertGreaterThan(loader.activeRequestCount, 0)
        loader.dispose(); loader.dispose()
        XCTAssertEqual(loader.activeRequestCount, 0)
        gate.complete(bytes)
        do { _ = try await task.value; XCTFail("Disposed asset loaded") } catch { }
        await Task.yield()
        XCTAssertEqual(loader.activeRequestCount, 0); XCTAssertNil(loader.lastError)
    }
    func testAVCancellationCancelsInjectedReadAndLeavesNoActiveRequest() async throws {
        let bytes = NativeSyntheticMedia.wave(), started = expectation(description: "AV requested bytes")
        var observedCancellation = false, signalledStart = false
        let loader = try NativeMediaResourceLoader(filename: "synthetic.wav", byteCount: Int64(bytes.count)) { _ in
            if !signalledStart { signalledStart = true; started.fulfill() }
            do { try await Task.sleep(nanoseconds: 30_000_000_000); return Data() }
            catch { observedCancellation = Task.isCancelled; throw error }
        }
        let asset = asset(loader)
        let task = Task { try await metadata(asset, loader: loader, mediaType: .audio) }
        await fulfillment(of: [started], timeout: 3)
        asset.cancelLoading(); task.cancel(); loader.dispose()
        do { _ = try await task.value; XCTFail() } catch { }
        // Drain the already-cancelled injected read on the main actor.
        for _ in 0..<20 { if observedCancellation { break }; await Task.yield() }
        XCTAssertTrue(observedCancellation); XCTAssertEqual(loader.activeRequestCount, 0); XCTAssertNil(loader.lastError)
    }
    #endif
    func testUnrelatedAssetCannotAttachOrInvokeInjectedRead() async throws {
        var reads = 0
        let loader = try NativeMediaResourceLoader(filename: "synthetic.wav", byteCount: 100) { _ in reads += 1; return Data() }
        let unrelated = AVURLAsset(url: URL(string: "native-chat-media://unrelated/media.wav")!)
        loader.attach(to: unrelated)
        XCTAssertEqual(loader.lastError as? ChatMediaRangeReadError, .invalidResponse)
        XCTAssertNil(unrelated.resourceLoader.delegate); XCTAssertEqual(reads, 0)
        loader.dispose()
    }
}

@MainActor private final class BlockingMediaReads {
    let started: XCTestExpectation
    private var waiting: [(ChatMediaByteRange, CheckedContinuation<Data, Error>)] = []
    init(started: XCTestExpectation) { self.started = started }
    func read(_ range: ChatMediaByteRange) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append((range, continuation)); if waiting.count == 1 { started.fulfill() }
        }
    }
    func complete(_ bytes: Data) {
        let requests = waiting; waiting = []
        for (range, continuation) in requests {
            continuation.resume(returning: bytes.subdata(in: Int(range.offset)..<(Int(range.end) + 1)))
        }
    }
}
