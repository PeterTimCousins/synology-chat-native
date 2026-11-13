import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// The player sees a private local file or an opaque resource URL, never a NAS session URL.
@MainActor final class NativeMediaPlayback:ObservableObject {
    let player:AVPlayer
    let kind:NativeDocumentKind
    let file:URL?
    let duration:Double
    @Published private(set) var failure:String?
    @Published private(set) var time:Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var volume:Float = 1
    @Published private(set) var rate:Float = 1
    private var timeObserver:Any?
    private var playingObservation:NSKeyValueObservation?
    private var statusObservation:NSKeyValueObservation?
    private var failureObserver:NSObjectProtocol?
    private var disposed = false
    private var resourceLoader: NativeMediaResourceLoader?
    private init(file:URL?,kind:NativeDocumentKind,asset:AVURLAsset,duration:Double,resourceLoader: NativeMediaResourceLoader? = nil) {
        self.file = file;self.kind = kind;self.duration = duration
        self.resourceLoader = resourceLoader
        let item = AVPlayerItem(asset:asset)
        player = AVPlayer(playerItem:item)
        player.actionAtItemEnd = .pause;player.allowsExternalPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,!self.disposed,time.seconds.isFinite else { return };self.time = min(self.duration,max(0,time.seconds))
            }
        }
        playingObservation = player.observe(\.timeControlStatus,options:[.new]) { [weak self] player,_ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in guard let self,!self.disposed else { return };self.isPlaying = playing }
        }
        statusObservation = item.observe(\.status,options:[.new]) { [weak self] item,_ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.reportFailure() }
        }
        failureObserver = NotificationCenter.default.addObserver(forName:.AVPlayerItemFailedToPlayToEndTime,object:item,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportFailure() }
        }
    }
    static func stream(kind: NativeDocumentKind, filename: String, byteCount: Int64,
                       read: @escaping @MainActor (ChatMediaByteRange) async throws -> Data) async throws -> NativeMediaPlayback {
        guard kind.isMedia, byteCount > 0, byteCount <= Int64(kind.limit) else { throw ChatAPIError.invalidResponse }
        try Task.checkCancellation()
        let loader = try NativeMediaResourceLoader(filename: filename, byteCount: byteCount, read: read)
        let asset = AVURLAsset(url: loader.url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        loader.attach(to: asset)
        do {
            return try await withTaskCancellationHandler(operation: {
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: kind == .video ? .video : .audio)
                let duration = try await asset.load(.duration).seconds
                try Task.checkCancellation()
                guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else { throw ChatAPIError.invalidResponse }
                return NativeMediaPlayback(file: nil, kind: kind, asset: asset, duration: duration, resourceLoader: loader)
            }, onCancel: {
                Task { @MainActor in loader.dispose(); asset.cancelLoading() }
            })
        } catch {
            let transferError = loader.lastError
            loader.dispose(); asset.cancelLoading()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let transferError { throw transferError }
            throw ChatTransferError(message: "This media could not be played. Try again, or save the original to open it in another app.")
        }
    }
    static func load(_ data:Data,kind:NativeDocumentKind,filename:String) async throws -> NativeMediaPlayback {
        guard kind == .audio || kind == .video,data.count <= kind.limit else { throw ChatAPIError.invalidResponse }
        try Task.checkCancellation()
        let suffix = (filename as NSString).pathExtension.lowercased()
        let file = try NativeMediaTemporaryFiles.shared.create(extension:suffix)
        do {
            try data.write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            let asset = AVURLAsset(url:file,options:[AVURLAssetReferenceRestrictionsKey:AVAssetReferenceRestrictions.forbidAll.rawValue])
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType:kind == .video ? .video : .audio)
            let duration = try await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard playable,!tracks.isEmpty,duration.isFinite,duration > 0 else { throw ChatTransferError(message:"This media format cannot be played on this Mac. Save the original to open it in another app.") }
            return NativeMediaPlayback(file:file,kind:kind,asset:asset,duration:duration)
        } catch {
            NativeMediaTemporaryFiles.shared.remove(file)
            if Task.isCancelled { throw CancellationError() }
            throw ChatTransferError(message:"This media could not be played. Try again, or save the original to open it in another app.")
        }
    }
    func togglePlayback() {
        guard !disposed,failure == nil else { return }
        if player.rate > 0 { player.pause();return }
        if time >= duration-0.05 {
            player.seek(to:.zero,toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] done in
                Task { @MainActor [weak self] in guard let self,done,!self.disposed else { return };self.player.playImmediately(atRate:self.rate) }
            }
        } else { player.playImmediately(atRate:rate) }
    }
    func seek(to seconds:Double) {
        guard !disposed,seconds.isFinite else { return };time = min(duration,max(0,seconds))
        player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    func setVolume(_ value:Float) { guard !disposed,value.isFinite else { return };volume = min(1,max(0,value));player.volume = volume }
    func setRate(_ value:Float) { guard !disposed,[Float(0.5),1,1.5,2].contains(value) else { return };rate = value;player.defaultRate = value;if player.rate > 0 { player.rate = value } }
    static func timeLabel(_ value:Double)->String { let seconds = value.isFinite ? Int(max(0,min(value,864000))) : 0;return String(format:"%d:%02d",seconds/60,seconds%60) }
    private func reportFailure() {
        guard !disposed else { return };player.pause()
        failure = "Playback stopped. Try again, or save the original to open it."
    }
    func dispose() {
        guard !disposed else { return };disposed = true
        player.pause();player.replaceCurrentItem(with:nil);isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) };timeObserver = nil
        playingObservation?.invalidate();playingObservation = nil
        statusObservation?.invalidate();statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) };failureObserver = nil
        resourceLoader?.dispose(); resourceLoader = nil
        if let file { NativeMediaTemporaryFiles.shared.remove(file) }
    }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        playingObservation?.invalidate()
        statusObservation?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.pause();player.replaceCurrentItem(with:nil)
        if let resourceLoader { Task { @MainActor in resourceLoader.dispose() } }
        if let file { NativeMediaTemporaryFiles.shared.remove(file) }
    }
}

struct NativeMediaPlayerView:View {
    @ObservedObject var playback:NativeMediaPlayback
    let retry:()->Void
    var body:some View {
        VStack(spacing:18) {
            if let failure = playback.failure {
                Image(systemName:"exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                Text(failure).multilineTextAlignment(.center).foregroundColor(NativeChatColors.muted).padding(.horizontal,30)
                Button("Try again",action:retry).buttonStyle(NativeSendButtonStyle())
            } else {
                if playback.kind == .audio { NativeAudioControls(playback:playback) }
                else { NativeAVPlayerView(player:playback.player).frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityLabel("Video playback") }
            }
        }.padding(playback.kind == .audio ? 24 : 0)
    }
}
private struct NativeAudioControls:View {
    @ObservedObject var playback:NativeMediaPlayback
    var body:some View {
        VStack(spacing:28) {
            Image(systemName:"waveform").font(.system(size:70,weight:.light)).foregroundColor(NativeChatColors.green)
                .frame(width:140,height:140).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:28))
            VStack(spacing:20) {
                HStack(spacing:20) {
                    Button { playback.seek(to:playback.time-15) } label: { Image(systemName:"gobackward.15").font(.title2) }.accessibilityLabel("Back 15 seconds")
                    Button { playback.togglePlayback() } label: {
                        Image(systemName:playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size:25,weight:.semibold))
                            .frame(width:60,height:60).foregroundColor(NativeChatColors.canvas).background(NativeChatColors.green).clipShape(Circle())
                    }.accessibilityLabel(playback.isPlaying ? "Pause audio" : "Play audio")
                    Button { playback.seek(to:playback.time+15) } label: { Image(systemName:"goforward.15").font(.title2) }.accessibilityLabel("Forward 15 seconds")
                }.buttonStyle(.plain)
                VStack(spacing:8) {
                    Slider(value:Binding(get:{ playback.time },set:{ playback.seek(to:$0) }),in:0...playback.duration).tint(NativeChatColors.green).accessibilityLabel("Audio position")
                    HStack { Text(NativeMediaPlayback.timeLabel(playback.time));Spacer();Text(NativeMediaPlayback.timeLabel(playback.duration)) }.font(.system(size:12,design:.monospaced)).foregroundColor(NativeChatColors.muted)
                }
                HStack(spacing:12) {
                    Image(systemName:playback.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundColor(NativeChatColors.muted)
                    Slider(value:Binding(get:{ Double(playback.volume) },set:{ playback.setVolume(Float($0)) }),in:0...1).frame(width:120).accessibilityLabel("Audio volume")
                    Spacer()
                    Menu { ForEach([Float(0.5),1,1.5,2],id:\.self) { value in Button(String(format:"%gx",value)) { playback.setRate(value) } } } label: { Text(String(format:"%gx",playback.rate)).font(.callout.monospacedDigit()) }.menuStyle(.borderlessButton).frame(width:60).accessibilityLabel("Audio speed")
                }
            }.padding(24).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:18))
        }.frame(maxWidth:480).frame(maxWidth:.infinity,maxHeight:.infinity).padding(20)
    }
}
private struct NativeAVPlayerView:NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context)->AVPlayerView {
        let view = AVPlayerView();view.controlsStyle = .inline;view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false;view.showsFullScreenToggleButton = true;view.player = player
        return view
    }
    func updateNSView(_ view:AVPlayerView,context:Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view:AVPlayerView,coordinator:()) { view.player?.pause();view.player = nil }
}
