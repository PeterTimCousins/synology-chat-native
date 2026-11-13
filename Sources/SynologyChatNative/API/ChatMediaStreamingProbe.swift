#if DEBUG
import Foundation
import AVFoundation

/// Real paused-player metadata/seek checks, confined to the two pinned own-account fixtures.
@MainActor enum ChatMediaStreamingProbe {
    static func run(receipt: URL) async -> Bool {
        var report: [String: Any] = ["scope": "Read-only paused native streaming of synthetic752/753 in verified own Peter93",
                                     "state": "not_started", "media": [[String: Any]]()]
        var activePlayback: NativeMediaPlayback?
        defer { activePlayback?.dispose() }
        do {
            guard !FileManager.default.fileExists(atPath: receipt.path) else { print("Stream receipt exists. No check repeated."); return false }
            try save(report, receipt, initial: true)
            let account = try OfficialChatSessionLoader.load(), api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let target = try ChatPeterProbeTarget.resolve(username: account.username, users: await api.users(),
                channels: await api.channels(), members: await api.members(channelID: 93))
            report["owner_id"] = target.ownerID; report["peer_id"] = target.peerID
            var media: [[String: Any]] = []
            for fixture in ChatMediaRangeFixture.all {
                try fixture.validate(await api.post(channelID: 93, postID: fixture.postID))
                var ranges: [[String: Any]] = []
                report["active_post_id"] = fixture.postID; report["state"] = "loading_paused_stream"
                try save(report, receipt)
                let task = Task { @MainActor in
                    try await NativeMediaPlayback.stream(kind: fixture.filename.hasSuffix(".wav") ? .audio : .video,
                        filename: fixture.filename, byteCount: Int64(fixture.count)) { range in
                        let data = try await api.mediaRangeData(postID: fixture.postID, range: range)
                        ranges.append(["range": range.header, "bytes": data.count])
                        return data
                    }
                }
                let watchdog = Task { try await Task.sleep(nanoseconds: 30_000_000_000); task.cancel() }
                let playback: NativeMediaPlayback
                do { playback = try await task.value; watchdog.cancel() }
                catch { watchdog.cancel(); throw error }
                activePlayback = playback
                guard playback.file == nil, playback.player.rate == 0,
                      let asset = playback.player.currentItem?.asset as? AVURLAsset,
                      asset.url.scheme == "native-chat-media", asset.url.query == nil,
                      asset.referenceRestrictions == .forbidAll, !playback.player.allowsExternalPlayback else { throw ChatAPIError.invalidResponse }
                playback.setVolume(0)
                let targetTime = playback.duration / 2
                let seekWatchdog = Task { try await Task.sleep(nanoseconds: 15_000_000_000); playback.dispose() }
                let sought = await withCheckedContinuation { continuation in
                    playback.player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                        continuation.resume(returning: $0)
                    }
                }
                seekWatchdog.cancel()
                let actual = playback.player.currentTime().seconds
                guard sought, actual.isFinite, abs(actual - targetTime) <= 0.15, playback.player.rate == 0, !ranges.isEmpty else { throw ChatAPIError.invalidResponse }
                playback.player.isMuted = true
                playback.togglePlayback()
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, playback.player.currentTime().seconds < actual + 0.12 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let progressed = playback.player.currentTime().seconds
                guard progressed.isFinite, progressed >= actual + 0.1, playback.failure == nil else { throw ChatAPIError.invalidResponse }
                if playback.player.rate > 0 { playback.togglePlayback() }
                guard playback.player.rate == 0 else { throw ChatAPIError.invalidResponse }
                let item: [String: Any] = ["post_id": fixture.postID, "filename": fixture.filename,
                    "duration": playback.duration, "seek_target": targetTime, "seek_actual": actual,
                    "seek_completed": sought, "autoplay": false, "explicit_muted_playback": true,
                    "playback_start": actual, "playback_end": progressed, "paused_after_play": true, "local_file": false, "player_url": "opaque_without_credentials",
                    "ranges": ranges, "completed_range_bytes": ranges.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }]
                playback.dispose()
                guard playback.player.currentItem == nil else { throw ChatAPIError.invalidResponse }
                activePlayback = nil
                media.append(item); report["media"] = media; report.removeValue(forKey: "active_post_id")
                try save(report, receipt)
            }
            report["state"] = "metadata_seek_muted_play_pause_and_cleanup_verified"
            report["no_messages_or_mutations"] = true
            try save(report, receipt)
            print("Native streaming, midpoint seeks, muted playback, pause and cleanup verified for the two own synthetic media files.")
            return true
        } catch {
            report["state"] = "stopped_without_mutation"
            report["error_kind"] = String(describing: type(of: error))
            if case ChatAPIError.server(let code) = error { report["api_error_code"] = code }
            try? save(report, receipt)
            print("Paused streaming check stopped; sanitized receipt saved. No message or account changes.")
            return false
        }
    }
    private static func save(_ report: [String: Any], _ receipt: URL, initial: Bool = false) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: receipt, options: initial ? .withoutOverwriting : .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }
}
#endif
