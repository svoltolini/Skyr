import SkyrCore
import AVKit
import MediaPlayer
import SwiftUI

/// Full player sheet: artwork, scrubber, transport, volume, and shuffle, AirPlay and repeat.
struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingToPlaylist = false
    @State private var previousTaps = 0
    @State private var nextTaps = 0
    @State private var playPauseTaps = 0
    @State private var modeTaps = 0

    @Environment(\.isWideLayout) private var isWide

    /// An iPad sheet is wide; the player keeps its controls in a phone-like column at its centre.
    private var contentWidth: CGFloat {
        #if os(tvOS)
        .infinity
        #else
        isWide ? 600 : .infinity
        #endif
    }

    /// The cover's ceiling: the television's is huge, an iPad sheet's a little larger than a phone's.
    private var artworkWidth: CGFloat {
        #if os(tvOS)
        640
        #else
        isWide ? 420 : 340
        #endif
    }

    var body: some View {
        if let track = player.track {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Group {
                    if let album = player.album {
                        ArtworkView(album: album, cornerRadius: 16, size: .hero)
                            .id(album.id)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: player.album?.id)
                .frame(maxWidth: artworkWidth)
                .shadow(color: .black.opacity(0.45), radius: 36, y: 24)
                .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.86)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8), value: player.isPlaying)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture(perform: openAlbum)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the album")
                Spacer(minLength: 24)

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        library.toggleFavourite(track)
                    } label: {
                        Image(systemName: library.isFavourite(track) ? "heart.fill" : "heart")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(library.isFavourite(track) ? Color.red : Color.primary)
                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: library.isFavourite(track))
                    .accessibilityLabel(library.isFavourite(track) ? "Remove from Favourites" : "Favourite")

                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        Text(player.album?.artist ?? player.queueTitle ?? " ")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        QualityBars(quality: track.quality, maxHeight: 9)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)

                    Menu {
                        if player.album != nil {
                            Button("Go to Album", systemImage: "square.stack") { openAlbum() }
                        }
                        Button("Add to Playlist…", systemImage: "text.badge.plus") {
                            isAddingToPlaylist = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More")
                }
                .animation(.easeInOut(duration: 0.25), value: track.id)
                .sheet(isPresented: $isAddingToPlaylist) {
                    AddToPlaylistSheet(tracks: [track])
                }

                PlaybackProgress()
                    .padding(.top, 22)

                if let error = player.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 10)
                }

                HStack(spacing: 44) {
                    Button {
                        previousTaps += 1
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .symbolEffect(.bounce, options: .speed(1.6), value: previousTaps)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .sensoryFeedback(.impact(weight: .light), trigger: previousTaps)
                    .accessibilityLabel("Previous track")

                    Button {
                        playPauseTaps += 1
                        player.togglePlayPause()
                    } label: {
                        PlayPauseGlyph(isPlaying: player.isPlaying, size: 28)
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .sensoryFeedback(.impact(weight: .medium), trigger: playPauseTaps)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        nextTaps += 1
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .symbolEffect(.bounce, options: .speed(1.6), value: nextTaps)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .sensoryFeedback(.impact(weight: .light), trigger: nextTaps)
                    .accessibilityLabel("Next track")
                }
                .padding(.top, 22)

                VolumeSlider()
                    .frame(height: 30)
                    .padding(.top, 26)

                HStack {
                    Button {
                        modeTaps += 1
                        player.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(player.isShuffling ? .primary : .secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .accessibilityLabel(player.isShuffling ? "Shuffle on" : "Shuffle off")
                    Spacer()
                    routePicker
                    Spacer()
                    Button {
                        modeTaps += 1
                        player.cycleRepeat()
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(player.repeatMode == .off ? .secondary : .primary)
                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .accessibilityLabel(repeatLabel)
                }
                .padding(.horizontal, 12)
                .padding(.top, modesRowTopPadding)
                .sensoryFeedback(.selection, trigger: modeTaps)
            }
            .frame(maxWidth: contentWidth)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
            .symbolEffectsRemoved(reduceMotion)
            .presentationDragIndicator(.visible)
            .presentationBackground {
                ZStack {
                    Palette.paper.mix(with: player.tint, by: colorScheme == .dark ? 0.35 : 0.3)
                    RadialGradient(
                        colors: [player.tint.opacity(0.5), .clear],
                        center: UnitPoint(x: 0.5, y: 0.35),
                        startRadius: 0,
                        endRadius: 420
                    )
                    .blur(radius: 60)
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// The system volume slider, tinted like the rest of the sheet.
/// The scrubber and time labels in their own view, so the quarter-second position updates redraw
/// only this strip and not the whole sheet with its artwork and glass buttons.
private struct PlaybackProgress: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(spacing: 8) {
            ScrubBar(progress: player.progress) { fraction in
                player.seek(toFraction: fraction)
            }
            HStack {
                Text(TimeText.clock(player.position))
                Spacer()
                Text("-" + TimeText.clock(player.remaining))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
private struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.tintColor = UIColor.label.withAlphaComponent(0.7)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// The AirPlay picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = .label
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#elseif os(tvOS)
/// The television's volume is the remote's business.
private struct VolumeSlider: View {
    var body: some View { EmptyView() }
}

/// The AirPlay picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
/// On the Mac the app's own level, not the system's.
private struct VolumeSlider: View {
    var body: some View { MacVolumeSlider() }
}

/// The AirPlay picker.
private struct RoutePicker: View {
    var body: some View { MacRoutePicker() }
}
#endif

extension NowPlayingView {
    /// The television's AirPlay button is a large system control that draws its own platter,
    /// so it keeps its natural size there and the row sits clear of the transport buttons.
    @ViewBuilder fileprivate var routePicker: some View {
        #if os(tvOS)
        RoutePicker()
            .fixedSize()
            .accessibilityLabel("AirPlay")
        #else
        RoutePicker()
            .frame(width: 44, height: 44)
            .accessibilityLabel("AirPlay")
        #endif
    }

    fileprivate var modesRowTopPadding: CGFloat {
        #if os(tvOS)
        40
        #else
        8
        #endif
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    /// Closes the sheet and shows the playing album in the Library tab.
    private func openAlbum() {
        guard let album = player.album else { return }
        dismiss()
        model.showAlbum(library.album(id: album.id) ?? album)
    }
}

/// Thin capsule progress bar that seeks on drag or tap.
struct ScrubBar: View {
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let fraction = dragFraction ?? progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                Capsule()
                    .fill(.primary.opacity(0.7))
                    .frame(width: max(0, geometry.size.width * fraction))
                    .animation(dragFraction == nil ? .linear(duration: 0.25) : nil, value: fraction)
            }
            .frame(height: dragFraction == nil ? 5 : 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -14))
            .modifier(ScrubGesture(width: geometry.size.width) { fraction in
                dragFraction = fraction
            } onEnd: { fraction in
                onSeek(fraction)
                dragFraction = nil
            })
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
        .frame(height: 9)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityPercent(Int((progress * 100).rounded()))
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            onSeek(direction == .increment ? min(1, progress + step) : max(0, progress - step))
        }
    }
}

/// Dragging along the bar seeks; the television has no drag, so its bar only shows progress.
private struct ScrubGesture: ViewModifier {
    let width: CGFloat
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onChange(Double(min(1, max(0, value.location.x / width)))) }
                .onEnded { value in onEnd(Double(min(1, max(0, value.location.x / width)))) }
        )
        #endif
    }
}
