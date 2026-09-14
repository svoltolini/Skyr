import AVKit
import SkyrCore
import SwiftUI

/// The transport across the bottom of the window: what is playing on the left, controls and the
/// scrubber in the middle, volume and AirPlay on the right.
struct MacPlayerBar: View {
    static let height: CGFloat = 76
    let openNowPlaying: () -> Void
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var showsVolume = false

    var body: some View {
        @Bindable var player = player
        GeometryReader { geometry in
        HStack(spacing: 16) {
            nowPlaying
                .frame(width: min(260, max(150, geometry.size.width * 0.26)), alignment: .leading)
            VStack(spacing: 4) {
                transport
                scrubber
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                if geometry.size.width >= 850 {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 100)
                    .accessibilityLabel("Volume")
                    .accessibilityValue(Text(player.volume, format: .percent.precision(.fractionLength(0))))
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                } else {
                    Button("Volume", systemImage: "speaker.wave.2.fill") { showsVolume.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showsVolume) { MacVolumeSlider().frame(width: 180).padding() }
                }
                MacRoutePicker()
                    .frame(width: 26, height: 26)
                    .padding(.leading, 4)
            }
            .frame(width: geometry.size.width >= 850 ? 185 : 72, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = player.track {
            HStack(spacing: 12) {
                Button(action: openNowPlaying) {
                    Group {
                        if let album = player.album {
                            ArtworkView(album: album, cornerRadius: 8, highlight: false, size: .row)
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Now Playing")
                .accessibilityLabel("Show Now Playing")
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.album?.artist ?? player.queueTitle ?? track.artist ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: track.id)
            }
        } else {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.tertiary)
                    }
                Text("Nothing playing")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.isShuffling ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Shuffle")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffling ? "On" : "Off")
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!player.hasTrack)
            .help("Previous")
            .accessibilityLabel("Previous Song")
            Button { player.togglePlayPause() } label: {
                PlayPauseGlyph(isPlaying: player.isPlaying, size: 24)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!player.hasTrack)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!player.hasTrack)
            .help("Next")
            .accessibilityLabel("Next Song")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Repeat")
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode == .off ? "Off" : player.repeatMode == .one ? "One Song" : "All Songs")
        }
        .foregroundStyle(.primary)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(TimeText.clock(scrubbing ? scrubValue * player.duration : player.position))
                .frame(width: 42, alignment: .trailing)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : player.progress },
                    set: { value in
                        scrubValue = value
                        // Keyboard and VoiceOver adjustments need not begin a mouse drag.
                        if !scrubbing { player.seek(toFraction: value) }
                    }
                ),
                in: 0...1
            ) { editing in
                if editing { scrubValue = player.progress }
                scrubbing = editing
                if !editing { player.seek(toFraction: scrubValue) }
            }
            .controlSize(.mini)
            .disabled(!player.hasTrack)
            .accessibilityLabel("Playback position")
            .accessibilityValue(playbackPositionDescription)
            Text("-" + TimeText.clock(scrubbing ? (1 - scrubValue) * player.duration : player.remaining))
                .frame(width: 42, alignment: .leading)
                .accessibilityHidden(true)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var playbackPositionDescription: Text {
        let elapsed = scrubbing ? scrubValue * player.duration : player.position
        let remaining = max(0, player.duration - elapsed)
        return Text("\(spokenDuration(elapsed)) elapsed, \(spokenDuration(remaining)) remaining")
    }

    private func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0 seconds" }
        return Duration.seconds(seconds.rounded(.down)).formatted(.units(
            allowed: [.hours, .minutes, .seconds], width: .wide
        ))
    }
}

/// The app's output level as a slider, used inside the Now Playing panel.
struct MacVolumeSlider: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $player.volume, in: 0...1)
                .accessibilityLabel("Volume")
                .accessibilityValue(Text(player.volume, format: .percent.precision(.fractionLength(0))))
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// The AirPlay picker.
struct MacRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
