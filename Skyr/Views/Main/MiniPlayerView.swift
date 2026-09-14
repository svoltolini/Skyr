import SkyrCore
import SwiftUI

/// Compact transport docked above the tab bar. Collapses when the tab bar minimises.
struct MiniPlayerView: View {
    let open: () -> Void
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var playPauseTaps = 0
    @State private var nextTaps = 0

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let track = player.track {
            HStack(spacing: 12) {
                Group {
                    if let album = player.album {
                        ArtworkView(album: album, cornerRadius: isInline ? 9 : 12, highlight: false, size: .row)
                    } else {
                        RoundedRectangle(cornerRadius: isInline ? 9 : 12, style: .continuous)
                            .fill(.quaternary)
                    }
                }
                .frame(width: isInline ? 30 : 40, height: isInline ? 30 : 40)
                VStack(alignment: .leading, spacing: 1) {
                    FadingText(track.title, fadeWidth: 40)
                        .font(.subheadline.weight(.medium))
                        .id(track.id)
                        .transition(.opacity)
                    if !isInline {
                        FadingText(player.album?.artist ?? player.queueTitle ?? track.artist ?? " ", fadeWidth: 40)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: track.id)
                Spacer(minLength: 8)
                Button {
                    playPauseTaps += 1
                    player.togglePlayPause()
                } label: {
                    PlayPauseGlyph(isPlaying: player.isPlaying, size: 18)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportButtonStyle())
                .sensoryFeedback(.impact(weight: .light), trigger: playPauseTaps)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                if !isInline {
                    Button {
                        nextTaps += 1
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.bounce, options: .speed(1.6), value: nextTaps)
                            .symbolEffectsRemoved(reduceMotion)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .sensoryFeedback(.impact(weight: .light), trigger: nextTaps)
                    .accessibilityLabel("Next track")
                }
            }
            .padding(.horizontal, isInline ? 10 : 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAction(named: "Open Now Playing", open)
        }
    }
}
