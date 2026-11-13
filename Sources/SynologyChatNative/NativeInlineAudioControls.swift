import SwiftUI

/// Playback lifetime and attachment identity belong to the parent card. These
/// controls do not start playback or acquire media when they appear.
struct NativeInlineAudioControls: View {
    @ObservedObject var playback: NativeMediaPlayback
    let retry: () -> Void
    let expand: () -> Void
    let stop: () -> Void
    @State private var showingVolume = false
    @State private var unmutedVolume: Float = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = playback.failure {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.orange).accessibilityHidden(true)
                    Text(failure).font(.system(size: 12)).foregroundColor(NativeChatColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("Retry", action: retry).buttonStyle(.borderedProminent)
                        .tint(NativeChatColors.green).controlSize(.small)
                        .help("Try loading this audio again")
                    Spacer(minLength: 8)
                    expandButton
                    stopButton
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: playback.togglePlayback) {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .offset(x: playback.isPlaying ? 0 : 1)
                            .foregroundColor(NativeChatColors.canvas)
                            .frame(width: 32, height: 32)
                            .background(NativeChatColors.green, in: Circle())
                            .contentShape(Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(playback.isPlaying ? "Pause audio" : "Play audio")
                        .help(playback.isPlaying ? "Pause" : "Play")
                    Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                           in: 0...playback.duration)
                        .controlSize(.small).tint(NativeChatColors.green)
                        .accessibilityLabel("Audio position")
                        .accessibilityValue("\(NativeMediaPlayback.timeLabel(playback.time)) of \(NativeMediaPlayback.timeLabel(playback.duration))")
                }
                HStack(spacing: 5) {
                    Text("\(NativeMediaPlayback.timeLabel(playback.time)) / \(NativeMediaPlayback.timeLabel(playback.duration))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(NativeChatColors.muted).fixedSize()
                        .accessibilityLabel("Elapsed \(NativeMediaPlayback.timeLabel(playback.time)), duration \(NativeMediaPlayback.timeLabel(playback.duration))")
                    Spacer(minLength: 0)
                    speedMenu
                    volumeButton
                    expandButton
                    stopButton
                }
            }
        }.frame(minWidth: 240, maxWidth: 420, alignment: .leading)
    }
    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in
                Button { playback.setRate(rate) } label: {
                    if playback.rate == rate { Label(speedLabel(rate), systemImage: "checkmark") }
                    else { Text(speedLabel(rate)) }
                }
            }
        } label: {
            Text(speedLabel(playback.rate)).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(NativeChatColors.muted).frame(width: 34, height: 30)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Playback speed").accessibilityValue(speedLabel(playback.rate))
            .help("Playback speed")
    }
    private var volumeButton: some View {
        Button { showingVolume.toggle() } label: {
            Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.2")
        }.buttonStyle(NativeToolbarButtonStyle())
            .accessibilityLabel("Audio volume").accessibilityValue("\(Int(playback.volume * 100)) percent")
            .help("Volume and mute")
            .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume").font(.system(size: 12, weight: .semibold)).foregroundColor(NativeChatColors.text)
                    HStack(spacing: 8) {
                        Button {
                            if playback.volume > 0 { unmutedVolume = playback.volume; playback.setVolume(0) }
                            else { playback.setVolume(unmutedVolume > 0 ? unmutedVolume : 1) }
                        } label: {
                            Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }.buttonStyle(NativeToolbarButtonStyle())
                            .accessibilityLabel(playback.volume == 0 ? "Unmute audio" : "Mute audio")
                            .help(playback.volume == 0 ? "Unmute" : "Mute")
                        Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.setVolume(Float($0)) }), in: 0...1)
                            .controlSize(.small).tint(NativeChatColors.green)
                            .accessibilityLabel("Audio volume")
                            .accessibilityValue("\(Int(playback.volume * 100)) percent")
                    }
                }.padding(12).frame(width: 190)
            }
    }
    private var expandButton: some View {
        Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Expand audio player")
            .help("Open full audio player")
    }
    private var stopButton: some View {
        Button(action: stop) { Image(systemName: "xmark") }
            .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Stop and close audio")
            .help("Stop and close audio")
    }
    private func speedLabel(_ rate: Float) -> String { String(format: "%g×", rate) }
}
